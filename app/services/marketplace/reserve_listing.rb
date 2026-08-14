# frozen_string_literal: true

require "digest"
require "json"

module Marketplace
  # Atomically turns one active listing into a resale checkout hold. The order
  # is deliberately built here instead of through Orders::CreateCheckout:
  # resale transfers the existing package and therefore must not reserve
  # primary inventory a second time.
  class ReserveListing < Core::BaseService
    include Ticketing::Suspensions::Support

    HOLD_DURATION = 10.minutes
    REVOCATION_REASON = "resale_checkout_reserved"

    class Abort < Core::Error
      attr_reader :business_error

      def initialize(business_error)
        @business_error = business_error
        super(business_error.message)
      end
    end

    def initialize(listing:, buyer:, idempotency_key:, answers: [], consents: [], at: Time.current)
      @listing = listing
      @buyer = buyer
      @answers = answers
      @consents = consents
      @now = at.to_time.utc.change(usec: 0)
      @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
    rescue ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(error(:invalid_idempotency_key, :unprocessable_entity)) if @initialization_error
      return failure(error(:buyer_invalid, :unprocessable_entity)) unless @buyer.is_a?(Core::User)

      prepare_keys
      outcome = nil
      ActiveRecord::Base.transaction do
        listing = ResaleListing.lock.find(@listing.id)
        existing = Orders::Order.lock.find_by(idempotency_key_digest: @order_key_digest)
        if existing
          outcome = replay_or_conflict(existing, listing)
          next
        end

        return failure(error(:listing_not_found, :not_found)) unless listing
        unless listing.status == "active"
          outcome = failure(error(:listing_reserved, :conflict))
          next
        end

        ticket = load_ticket(listing)
        verify_reservation_eligibility!(listing, ticket)
        Core::Database::AdvisoryLock.acquire!("orders-checkout", @buyer.id, ticket.event_id)
        reject_existing_checkout!(ticket)

        registration = create_buyer_registration!(ticket)
        commercial = resolve_commercial!(listing, ticket)
        order = create_order!(listing, commercial)
        item = create_order_item!(order, listing, ticket, registration)
        write_adjustments!(order, item, commercial.fetch(:buyer_result))
        reconcile_item_total!(item)
        reserve_purchase_limit!(registration, item, order)
        order.update!(status: "pending_payment")

        projection = revoke_and_suspend_seller_access!(ticket)
        listing.update!(
          status: "reserved",
          reserved_order: order,
          reserved_at: @now,
          reservation_expires_at: order.expires_at
        )
        record_reservation!(listing, order)
        publish_reservation!(listing, order, projection)
        # The deadline job is scheduled only after the reservation effects are
        # inside the transaction; Rails defers the enqueue until commit so a
        # worker cannot observe a half-built resale hold.
        Marketplace::ExpireReservationJob
          .set(wait_until: order.expires_at)
          .perform_later(listing.id)
        outcome = success(order.reload)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(error(:reservation_record_not_found, :not_found))
    rescue Abort => exception
      failure(exception.business_error)
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:reservation_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      failure(error(:listing_reserved, :conflict))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :buyer, :now

    def prepare_keys
      digest = @idempotency_key.digest
      @order_key = "marketplace-resale-reservation-#{@listing.id}-#{digest}"
      @order_key_digest = Core::IdempotencyKey.new(@order_key).digest
      @request_digest = Digest::SHA256.hexdigest(JSON.generate(
        canonical(
          listing_id: @listing.id,
          buyer_id: @buyer.id,
          asking_amount_minor: @listing.asking_amount_minor,
          currency: @listing.currency
        )
      ))
    end

    def load_ticket(locked_listing)
      Ticketing::Ticket.includes(
        :event,
        :owner_user,
        :revocation,
        registration: :consent_requirements,
        current_credential_generation: :credentials,
        admission_slots: :assigned_user,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).lock.find(locked_listing.ticket_id)
    end

    def verify_reservation_eligibility!(locked_listing, ticket)
      abort_with(error(:ticket_not_active, :conflict)) unless ticket.status == "active"
      abort_with(error(:package_dead, :conflict)) if ticket.package_dead?
      abort_with(error(:package_suspended, :conflict)) if ticket.package_suspended?
      abort_with(error(:listing_seller_changed, :conflict)) unless ticket.owner_user_id == locked_listing.seller_user_id
      abort_with(error(:resale_disabled, :conflict)) unless ticket.event_product.ticket_type.resale_enabled
      abort_with(error(:resale_cutoff_passed, :conflict)) unless locked_listing.resale_cutoff_at > now
      abort_with(error(:resale_count_exhausted, :conflict)) if
        ticket.completed_resale_count >= locked_listing.max_completed_resales_snapshot
      abort_with(error(:group_mode_required, :conflict)) unless current_group_generation?(ticket)
      abort_with(error(:package_already_used, :conflict)) if active_admission_use?(ticket)
      abort_with(error(:pending_transfer, :conflict)) if pending_transfer?(ticket)
      abort_with(error(:active_claim, :conflict)) if active_claim?(ticket)
      abort_with(error(:active_refund, :conflict)) if active_refund?(ticket)
    end

    def current_group_generation?(ticket)
      generation = ticket.current_credential_generation
      ticket.credential_mode == "group" && generation&.status == "active" && generation.mode == "group" &&
        generation.version == ticket.credential_version
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
        .where(ticket_id: ticket.id, orders_refunds: { status: %w[created pending_funds processing succeeded] })
        .exists?
    end

    def reject_existing_checkout!(ticket)
      return unless Orders::Order.active_checkouts.lock.where(
        event_id: ticket.event_id,
        buyer_user_id: buyer.id
      ).exists?

      abort_with(error(:buyer_checkout_active, :conflict))
    end

    def create_buyer_registration!(ticket)
      submission = Ticketing::RegistrationSubmission.new(
        package_quantity: 1,
        selected_event_date_id: ticket.registration&.selected_event_date_id,
        answers: @answers,
        consents: @consents
      )
      result = Ticketing::Registrations::Submit.call(
        ticket_type: ticket.event_product.ticket_type,
        actor: buyer,
        phone: buyer.phone,
        submission:,
        audience_proof: {},
        idempotency_key: "marketplace-resale-registration-#{@listing.id}-#{@idempotency_key.digest}"
      )
      abort_with(result.error) if result.failure?

      result.value.registration
    end

    def resolve_commercial!(locked_listing, ticket)
      context = Commercial::Resolution::Context.new(
        organization_id: ticket.event.organization_id,
        event_id: ticket.event_id,
        event_product_id: ticket.event_product_id,
        product_type: ticket.event_product.type,
        sale_context: "resale",
        sales_channel: "resale",
        currency: locked_listing.currency,
        settlement_currency: locked_listing.currency,
        quoted_at: now,
        item_face_value_minor: locked_listing.asking_amount_minor,
        item_net_value_after_organizer_promotion_minor: locked_listing.asking_amount_minor,
        eligible_order_subtotal_minor: locked_listing.asking_amount_minor,
        resale_acquisition_amount_minor: locked_listing.asking_amount_minor,
        accepted_paid_units: 1,
        accepted_gross_minor: locked_listing.asking_amount_minor,
        organizer_payer_selections: {}
      )
      result = Commercial::ResolveCharges.call(
        context:,
        only_version: locked_listing.commercial_fee_schedule_version
      )
      abort_with(error(:commercial_terms_unavailable, :unprocessable_entity)) if result.failure?

      charge_result = result.value
      resale_component = charge_result.component_results.find do |component|
        component.component_type == "resale_platform_fee"
      end
      unless resale_component&.component_id.to_s == locked_listing.commercial_fee_component_id.to_s &&
        resale_component.version_id.to_s == locked_listing.commercial_fee_schedule_version_id.to_s
        abort_with(error(:commercial_terms_changed, :conflict))
      end
      abort_with(error(:commercial_terms_unavailable, :conflict)) unless
        resale_component.amount_minor <= locked_listing.asking_amount_minor

      buyer_result = buyer_charge_result(charge_result)
      {
        charge_result:,
        buyer_result:,
        resale_component:
      }
    end

    # The seller-side marketplace fee belongs to the listing/sale ledger. It
    # must not become a buyer charge merely because the same Commercial
    # resolution also carries organizer-side evidence.
    def buyer_charge_result(charge_result)
      components = charge_result.component_results.reject do |component|
        component.component_type == "resale_platform_fee"
      end
      Commercial::Resolution::ChargeResult.new(
        currency: charge_result.currency,
        settlement_currency: charge_result.settlement_currency,
        quoted_at: charge_result.quoted_at,
        component_results: components,
        buyer_fee_total: components.sum do |component|
          component.component_type != "platform_subsidy" && component.payer == "buyer" ? component.amount_minor : 0
        end,
        organizer_fee_total: components.sum do |component|
          component.component_type != "platform_subsidy" && component.payer == "organizer" ? component.amount_minor : 0
        end,
        subsidy_total: components.sum do |component|
          component.component_type == "platform_subsidy" ? component.amount_minor : 0
        end
      )
    end

    def create_order!(locked_listing, commercial)
      buyer_result = commercial.fetch(:buyer_result)
      gross = locked_listing.asking_amount_minor
      Orders::Order.create!(
        event_id: locked_listing.event_id,
        buyer_user_id: buyer.id,
        sales_channel: "resale",
        status: "draft",
        charge_currency: locked_listing.currency,
        commercial_signature: Orders::CommercialSignature.call(
          commercial_results: [ buyer_result ],
          charge_currency: locked_listing.currency
        ),
        subtotal_minor: gross,
        discount_minor: 0,
        subsidy_minor: buyer_result.subsidy_total,
        fee_minor: buyer_result.buyer_fee_total,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: gross - buyer_result.subsidy_total + buyer_result.buyer_fee_total,
        settlement_currency: locked_listing.currency,
        # The buyer's settlement snapshot is the gross amount they paid. The
        # seller-side resale fee is deducted only in Marketplace's separate
        # append-only ledger, never from the buyer order's settlement fact.
        settlement_total_minor: gross,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        expires_at: now + HOLD_DURATION,
        idempotency_key_digest: @order_key_digest,
        creation_request_digest: @request_digest
      )
    end

    def create_order_item!(order, locked_listing, ticket, registration)
      product = ticket.event_product
      order.order_items.create!(
        event_product: product,
        registration:,
        resale_listing_id: locked_listing.id,
        name_snapshot: product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: ticket.admissions_per_unit_snapshot,
        base_currency: locked_listing.currency,
        base_unit_amount_minor: locked_listing.asking_amount_minor,
        charge_currency: locked_listing.currency,
        charge_unit_amount_minor: locked_listing.asking_amount_minor,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: locked_listing.asking_amount_minor,
        fulfillment_status: "pending"
      )
    end

    def write_adjustments!(order, item, buyer_result)
      result = Orders::CommercialAdjustmentWriter.call(
        order:,
        order_item: item,
        charge_result: buyer_result
      )
      abort_with(result.error) if result.failure?
    end

    def reconcile_item_total!(item)
      buyer_adjustments = Orders::OrderAdjustment.where(order_item_id: item.id, charged_to: "buyer")
      item.update!(total_minor: item.charge_unit_amount_minor + buyer_adjustments.sum(:amount_minor))
    end

    def reserve_purchase_limit!(registration, item, order)
      result = Ticketing::PurchaseLimits::Reserve.call(
        registration:,
        user: buyer,
        quantity: item.quantity,
        expires_at: order.expires_at,
        idempotency_key: "marketplace-resale-purchase-limit-#{order.id}"
      )
      abort_with(result.error) if result.failure?
    end

    def revoke_and_suspend_seller_access!(ticket)
      generation = ticket.current_credential_generation
      credentials = generation.credentials.lock.to_a
      revocation = Ticketing::Revocations::PublishGeneration.call(
        ticket:,
        through_version: generation.version,
        reason: REVOCATION_REASON
      )
      abort_with(revocation.error) if revocation.failure?

      credentials.each do |credential|
        projection = Ticketing::AttendeeIndex::Upsert.call(
          credential:,
          loaded_credential: credential,
          removed: true
        )
        abort_with(projection.error) if projection.failure?
      end

      event = Events::Event.lock.find(ticket.event_id)
      package_revocation = revocation.value
      # Reuse the shared suspension projection so this marketplace transition
      # advances the same event-wide revocation cursor as review workflows.
      version = publish_projection!(
        ticket:,
        event:,
        revocation: package_revocation,
        is_dead: false,
        is_suspended: true,
        revoked_through_version: generation.version
      )
      {
        generation_version: generation.version,
        revocation_version: version,
        attendee_index_version: event.attendee_index_version
      }
    end

    def replay_or_conflict(existing_order, locked_listing)
      item = Orders::OrderItem.find_by(order_id: existing_order.id, resale_listing_id: locked_listing.id)
      return success(existing_order) if existing_order.event_id == locked_listing.event_id &&
        existing_order.buyer_user_id == buyer.id && item &&
        existing_order.creation_request_digest == @request_digest

      failure(error(:idempotency_conflict, :conflict))
    end

    def record_reservation!(locked_listing, order)
      result = Core::Audit::Record.call(
        # A listing can be relisted after a failed hold, so each reservation
        # cycle needs its own immutable audit identity.
        audit_key: "marketplace-resale-listing-reserved-#{order.id}",
        action: "marketplace.resale_listing.reserved",
        auditable_type: locked_listing.class.name,
        auditable_id: locked_listing.id,
        actor_type: buyer.class.name,
        actor_id: buyer.id,
        audited_changes: { status: [ "active", "reserved" ], reserved_order_id: order.id },
        metadata: { event_id: locked_listing.event_id, ticket_id: locked_listing.ticket_id, order_id: order.id }
      )
      abort_with(result.error) if result.failure?
    end

    def publish_reservation!(locked_listing, order, projection)
      result = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_listing.reserved",
        aggregate: locked_listing,
        payload: {
          listing_id: locked_listing.id,
          event_id: locked_listing.event_id,
          ticket_id: locked_listing.ticket_id,
          order_id: order.id,
          total_minor: order.total_minor,
          currency: order.charge_currency,
          seller_generation_version: projection.fetch(:generation_version),
          revocation_version: projection.fetch(:revocation_version),
          attendee_index_version: projection.fetch(:attendee_index_version)
        },
        idempotency_key: "marketplace-resale-listing-reserved-#{order.id}"
      )
      abort_with(result.error) if result.failure?
    end

    def abort_with(business_error)
      raise Abort, business_error
    end

    def canonical(value)
      case value
      when Hash
        value.stringify_keys.sort.to_h { |key, child| [ key, canonical(child) ] }
      when Array
        value.map { |child| canonical(child) }
      else
        value
      end
    end

    def error(code, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"), code:, status:, errors:
      )
    end
  end
end
