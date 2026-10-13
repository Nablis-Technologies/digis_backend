# frozen_string_literal: true

module Marketplace
  # Converts one accepted resale payment into an immutable sale and a new buyer
  # credential generation. The listing lock is the idempotency boundary: every
  # ownership, purchase-limit, generation, suspension, ledger, audit, and
  # outbox effect is committed together or rolled back together.
  class FulfillSale < Core::BaseService
    include Ticketing::Suspensions::Support

    class Abort < Core::Error
      attr_reader :business_error

      def initialize(business_error)
        @business_error = business_error
        super(business_error.message)
      end
    end

    def initialize(listing:, order:, payment:, at: Time.current)
      @listing = listing
      @order = order
      @payment = payment
      @now = at.to_time.utc.change(usec: 0)
      @idempotency_key = "marketplace-resale-sale-#{listing.id}-#{payment.id}"
    end

    def call
      ticket_type_id = ResaleListing.where(id: @listing.id).pick(:ticket_type_id)
      raise ActiveRecord::RecordNotFound unless ticket_type_id

      outcome = nil
      ActiveRecord::Base.transaction do
        Orders::CheckoutLock.acquire_for_order!(order_id: @order.id, ticket_type_ids: [ ticket_type_id ])
        listing = ResaleListing.lock.find(@listing.id)
        existing = ResaleSale.lock.find_by(resale_listing_id: listing.id)
        if existing
          outcome = replay_or_conflict(existing)
          next
        end

        order = Orders::Order.lock.find(listing.reserved_order_id)
        payment = Orders::Payment.lock.find(@payment.id)
        event = Events::Event.lock.find(order.event_id)
        ticket = load_ticket(listing)
        ticket_type = Ticketing::TicketType.lock.find(ticket.event_product.ticket_type.id)
        generations = lock_generations(ticket)
        slots = Ticketing::AdmissionSlot.where(ticket_id: ticket.id).lock.order(:position).to_a
        items = lock_order_items(order)
        item = validate_payment_and_order!(listing, order, payment, items, ticket)
        registration = item.registration
        current_generation = generations.find { |generation| generation.id == ticket.current_credential_generation_id }
        seller_item = validate_ticket_and_policy!(
          listing, event, ticket, ticket_type, current_generation, slots
        )
        allocations = lock_buyer_allocations(registration, order.buyer_user_id, ticket_type)
        commercial = resolve_resale_component!(listing, order, event, ticket)

        sale = create_sale!(
          listing:, event:, ticket:, order:, payment:, item:, registration:, seller_item:, commercial:
        )
        commit_buyer_allocation!(registration, order.buyer_user, item, allocations)
        listing.update!(status: "sold", sold_at: now, closed_at: now)

        replacement = replace_buyer_generation!(ticket, sale)
        abort_with(replacement.error) if replacement.failure?

        ticket.reload
        ticket.update!(
          owner_user: order.buyer_user,
          current_acquisition_type: "resale_purchase",
          current_acquisition_order_item: item,
          current_acquisition_product_value_minor: sale.gross_amount_minor,
          current_acquisition_currency: sale.currency,
          completed_resale_count: sale.resale_number
        )

        current_ticket = clear_package_suspension!(ticket, event, current_generation)
        item.update!(fulfillment_status: "fulfilled") unless item.fulfilled?
        order.update!(status: "fulfilled") unless order.status == "fulfilled"
        post_seller_ledger!(sale, event)
        record_sale!(sale, order.buyer_user)
        publish_sale!(sale, current_ticket, event)
        outcome = success(sale.reload)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(error(:sale_record_not_found, :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:sale_invalid, :conflict, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      replay = ResaleSale.find_by(resale_listing_id: @listing.id)
      return success(replay) if replay && replay_matches_request?(replay)

      failure(error(:sale_conflict, :conflict))
    rescue Abort => exception
      failure(exception.business_error)
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :now

    def replay_or_conflict(sale)
      return success(sale) if replay_matches_request?(sale)

      failure(error(:sale_idempotency_conflict, :conflict))
    end

    def replay_matches_request?(sale)
      sale.buyer_order_id == @order.id && sale.accepted_payment_id == @payment.id
    end

    def load_ticket(listing)
      Ticketing::Ticket.includes(
        :event,
        :owner_user,
        :revocation,
        current_acquisition_order_item: :order,
        current_credential_generation: :credentials,
        admission_slots: :assigned_user,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).lock.find(listing.ticket_id)
    end

    def lock_generations(ticket)
      Ticketing::CredentialGeneration.where(ticket_id: ticket.id).includes(:credentials).lock.order(:version).to_a
    end

    def lock_order_items(order)
      Orders::OrderItem.lock.includes(:registration).where(order_id: order.id).order(:id).to_a
    end

    def validate_payment_and_order!(listing, order, payment, items, ticket)
      abort_with(error(:sale_order_mismatch, :conflict)) unless order.id == @order.id &&
        order.event_id == listing.event_id && order.buyer_user_id == @order.buyer_user_id
      abort_with(error(:resale_order_required, :conflict)) unless order.sales_channel == "resale"
      abort_with(error(:payment_not_accepted, :conflict)) unless payment.status == "succeeded" && payment.accepted?
      abort_with(error(:payment_order_mismatch, :conflict)) unless payment.order_id == order.id
      abort_with(error(:payment_amount_mismatch, :conflict)) unless payment.amount_minor == order.total_minor &&
        payment.currency == order.charge_currency
      abort_with(error(:sale_order_mismatch, :conflict)) unless order.settlement_total_minor == listing.asking_amount_minor &&
        order.settlement_currency == listing.currency
      abort_with(error(:sale_order_mismatch, :conflict)) unless items.length == 1

      item = items.first
      abort_with(error(:sale_order_item_mismatch, :conflict)) unless item.resale_listing_id == listing.id &&
        item.type_snapshot == "ticket" && item.quantity == 1 && item.event_product_id == ticket.event_product_id
      abort_with(error(:sale_registration_mismatch, :conflict)) unless item.registration&.user_id == order.buyer_user_id
      item
    end

    def validate_ticket_and_policy!(listing, event, ticket, ticket_type, generation, slots)
      abort_with(error(:event_not_active, :conflict)) if event.status.in?(%w[cancelled completed])
      abort_with(error(:ticket_not_active, :conflict)) unless ticket.status == "active"
      abort_with(error(:package_dead, :conflict)) if ticket.package_dead?
      abort_with(error(:package_suspension_missing, :conflict)) unless ticket.package_suspended?
      abort_with(error(:listing_seller_changed, :conflict)) unless ticket.owner_user_id == listing.seller_user_id
      abort_with(error(:resale_disabled, :conflict)) unless ticket_type.resale_enabled
      abort_with(error(:resale_cutoff_passed, :conflict)) unless listing.resale_cutoff_at > now
      abort_with(error(:resale_count_changed, :conflict)) unless ticket.completed_resale_count == listing.resale_count_before
      abort_with(error(:resale_count_exhausted, :conflict)) if
        ticket.completed_resale_count >= listing.max_completed_resales_snapshot ||
        ticket.completed_resale_count >= ticket_type.max_completed_resales
      abort_with(error(:resale_cap_changed, :conflict)) unless listing.asking_amount_minor <= listing.calculated_cap_minor
      abort_with(error(:resale_acquisition_changed, :conflict)) unless
        ticket.current_acquisition_product_value_minor == listing.seller_acquisition_product_value_minor &&
        ticket.current_acquisition_currency == listing.currency
      abort_with(error(:group_mode_required, :conflict)) unless ticket.credential_mode == "group" &&
        generation&.mode == "group" && generation.status == "revoked" &&
        generation.version == ticket.credential_version
      abort_with(error(:invalid_generation_slots, :conflict)) unless
        slots.map(&:position) == (1..ticket.admissions_per_unit_snapshot).to_a
      abort_with(error(:package_already_used, :conflict)) if active_admission_use?(ticket)
      abort_with(error(:pending_transfer, :conflict)) if pending_transfer?(ticket)
      abort_with(error(:active_claim, :conflict)) if active_claim?(ticket)
      abort_with(error(:active_refund, :conflict)) if active_refund?(ticket)

      seller_item = ticket.current_acquisition_order_item
      abort_with(error(:seller_acquisition_missing, :conflict)) unless seller_item&.fulfilled? && seller_item.order.paid?
      seller_item
    end

    def lock_buyer_allocations(registration, buyer_id, ticket_type)
      allocations = Ticketing::PurchaseLimitAllocation.where(
        registration_id: registration.id,
        user_id: buyer_id,
        ticket_type_id: ticket_type.id,
        status: %w[reserved committed]
      ).lock.order(:unit_number).to_a
      if purchase_limit_enforced?(ticket_type, registration, buyer_id)
        abort_with(error(:buyer_allocation_missing, :conflict)) unless allocations.one?
      end

      allocations
    end

    def purchase_limit_enforced?(ticket_type, registration, buyer_id)
      return true if ticket_type.max_packages_per_user.present?

      Ticketing::PurchaseLimitOverride.where(
        registration_id: registration.id,
        ticket_type_id: ticket_type.id,
        user_id: buyer_id
      ).exists?
    end

    def resolve_resale_component!(listing, order, event, ticket)
      value = listing.asking_amount_minor
      context = Commercial::Resolution::Context.new(
        organization_id: event.organization_id,
        event_id: event.id,
        event_product_id: ticket.event_product_id,
        product_type: ticket.event_product.type,
        sale_context: "resale",
        sales_channel: "resale",
        currency: listing.currency,
        settlement_currency: listing.currency,
        quoted_at: listing.activated_at || now,
        item_face_value_minor: value,
        item_net_value_after_organizer_promotion_minor: value,
        eligible_order_subtotal_minor: value,
        resale_acquisition_amount_minor: value,
        accepted_paid_units: 1,
        accepted_gross_minor: value,
        organizer_payer_selections: {}
      )
      result = Commercial::ResolveCharges.call(
        context:, only_version: listing.commercial_fee_schedule_version
      )
      abort_with(error(:commercial_terms_unavailable, :conflict)) if result.failure?

      components = result.value.component_results.select { |component|
        component.component_type == "resale_platform_fee"
      }
      component = components.one? && components.first
      abort_with(error(:commercial_terms_changed_before_fulfillment, :conflict)) unless component &&
        component.component_id.to_s == listing.commercial_fee_component_id.to_s &&
        component.version_id.to_s == listing.commercial_fee_schedule_version_id.to_s &&
        component.amount_minor <= value

      {
        component:,
        fee_component: Commercial::FeeComponent.lock.find(component.component_id),
        fee_version: listing.commercial_fee_schedule_version,
        fee_minor: component.amount_minor,
        gross_minor: value
      }
    end

    def create_sale!(listing:, event:, ticket:, order:, payment:, item:, registration:, seller_item:, commercial:)
      component = commercial.fetch(:component)
      ResaleSale.create!(
        resale_listing: listing,
        event:,
        ticket:,
        seller_user: listing.seller_user,
        buyer_user: order.buyer_user,
        buyer_registration: registration,
        buyer_order: order,
        buyer_order_item: item,
        accepted_payment: payment,
        seller_acquisition_order_item: seller_item,
        resale_number: listing.resale_count_before + 1,
        gross_amount_minor: commercial.fetch(:gross_minor),
        currency: listing.currency,
        marketplace_fee_minor: commercial.fetch(:fee_minor),
        seller_proceeds_minor: commercial.fetch(:gross_minor) - commercial.fetch(:fee_minor),
        commercial_fee_component: commercial.fetch(:fee_component),
        commercial_fee_schedule_version: commercial.fetch(:fee_version),
        fee_calculation_type: component.calculation_type,
        fee_basis_type: component.basis_type || "accepted_gross",
        fee_fixed_amount_minor: component.fixed_amount_minor || 0,
        fee_rate_bps: component.rate_bps || 0,
        fee_minimum_minor: component.minimum_minor,
        fee_maximum_minor: component.maximum_minor,
        status: "completed",
        completed_at: now,
        idempotency_key: @idempotency_key
      )
    end

    def commit_buyer_allocation!(registration, buyer, item, allocations)
      return if allocations.empty?
      return if allocations.all?(&:committed?)

      result = Ticketing::PurchaseLimits::Commit.call(
        registration:,
        user: buyer,
        idempotency_key: "orders-purchase-limit-#{item.id}",
        at: now
      )
      abort_with(result.error) if result.failure?
    end

    def replace_buyer_generation!(ticket, sale)
      Ticketing::CredentialGenerations::Replace.call(
        ticket:,
        target_mode: "group",
        reason: "resale_sale_completed",
        assignments: {},
        idempotency_key: "marketplace-resale-generation-#{sale.id}",
        allow_suspended: true
      )
    end

    def clear_package_suspension!(ticket, event, previous_generation)
      refreshed_ticket = Ticketing::Ticket.lock.find(ticket.id)
      revocation = Ticketing::Revocation.lock.find_by!(ticket_id: ticket.id)
      publish_projection!(
        ticket: refreshed_ticket,
        event:,
        revocation:,
        is_dead: false,
        is_suspended: false,
        revoked_through_version: previous_generation.version
      )
      Ticketing::Ticket.includes(:revocation).lock.find(ticket.id)
    end

    def post_seller_ledger!(sale, event)
      Core::Database::AdvisoryLock.acquire!("marketplace-seller-ledger", sale.seller_user_id, event.id, sale.currency)
      create_or_replay_ledger_entry!(
        sale:, event:, type: "resale_proceeds", amount_minor: sale.gross_amount_minor,
        available_at: now, idempotency_key: "marketplace-resale-proceeds-#{sale.id}",
        description: I18n.t("marketplace.resale.ledger_descriptions.resale_proceeds")
      )
      create_or_replay_ledger_entry!(
        sale:, event:, type: "marketplace_fee", amount_minor: -sale.marketplace_fee_minor,
        available_at: now, idempotency_key: "marketplace-resale-fee-#{sale.id}",
        description: I18n.t("marketplace.resale.ledger_descriptions.marketplace_fee")
      )
    end

    def create_or_replay_ledger_entry!(sale:, event:, type:, amount_minor:, available_at:, idempotency_key:, description:)
      attributes = {
        seller_user: sale.seller_user,
        event:,
        resale_sale: sale,
        type:,
        amount_minor:,
        currency: sale.currency,
        available_at:,
        idempotency_key:,
        description:,
        created_at: now
      }
      existing = SellerLedgerEntry.lock.find_by(idempotency_key:)
      if existing
        return existing if existing.attributes.slice(
          "seller_user_id", "event_id", "resale_sale_id", "type", "amount_minor", "currency"
        ) == attributes.slice(:seller_user_id, :event_id, :resale_sale_id, :type, :amount_minor, :currency).stringify_keys

        abort_with(error(:seller_ledger_conflict, :conflict))
      end
      SellerLedgerEntry.create!(attributes)
    end

    def record_sale!(sale, buyer)
      result = Core::Audit::Record.call(
        audit_key: "marketplace-resale-sale-completed-#{sale.id}",
        action: "marketplace.resale_sale.completed",
        auditable_type: sale.class.name,
        auditable_id: sale.id,
        actor_type: buyer.class.name,
        actor_id: buyer.id,
        audited_changes: { status: "completed", resale_number: sale.resale_number },
        metadata: {
          event_id: sale.event_id,
          ticket_id: sale.ticket_id,
          listing_id: sale.resale_listing_id,
          buyer_order_id: sale.buyer_order_id,
          accepted_payment_id: sale.accepted_payment_id
        }
      )
      abort_with(result.error) if result.failure?
    end

    def publish_sale!(sale, ticket, event)
      result = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_sale.completed",
        aggregate: sale,
        payload: {
          sale_id: sale.id,
          listing_id: sale.resale_listing_id,
          event_id: event.id,
          ticket_id: ticket.id,
          seller_user_id: sale.seller_user_id,
          buyer_user_id: sale.buyer_user_id,
          order_id: sale.buyer_order_id,
          payment_id: sale.accepted_payment_id,
          resale_number: sale.resale_number,
          credential_version: ticket.credential_version,
          revocation_version: ticket.revocation.revocation_version
        },
        idempotency_key: "marketplace-resale-sale-completed-#{sale.id}"
      )
      abort_with(result.error) if result.failure?
    end

    def active_admission_use?(ticket)
      Ticketing::AdmissionUse
        .joins(:admission_slot)
        .where(ticketing_admission_slots: { ticket_id: ticket.id })
        .where.not(id: Ticketing::AdmissionUseReversal.select(:admission_use_id))
        .exists?
    end

    def pending_transfer?(ticket)
      Ticketing::TicketTransfer.where(ticket_id: ticket.id, status: "pending").exists?
    end

    def active_claim?(ticket)
      Ticketing::CredentialClaim
        .joins(credential: :credential_generation)
        .where(ticketing_credential_generations: { ticket_id: ticket.id }, status: %w[pending accepted])
        .exists?
    end

    def active_refund?(ticket)
      Orders::RefundItem
        .joins(:refund)
        .where(ticket_id: ticket.id, orders_refunds: { status: Orders::Refund::OUTSTANDING_STATUSES })
        .exists?
    end

    def abort_with(business_error)
      raise Abort, business_error
    end

    def error(code, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"), code:, status:, errors:
      )
    end
  end
end
