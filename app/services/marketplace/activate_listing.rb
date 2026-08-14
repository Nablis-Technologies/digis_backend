# frozen_string_literal: true

module Marketplace
  # Creates one immutable seller offer for a complete paid package. The ticket
  # row is the first lock in the command; every eligibility fact is re-read
  # under that lock so a concurrent delegation, refund, use, or listing cannot
  # race a successful activation.
  class ActivateListing < Core::BaseService
    PAID_ACQUISITION_TYPES = Ticketing::Ticket::PAID_ACQUISITION_TYPES.freeze
    ACTIVE_CLAIM_STATUSES = %w[pending accepted].freeze
    ACTIVE_REFUND_STATUSES = %w[created pending_funds processing succeeded].freeze

    def initialize(ticket:, actor:, asking_amount_minor:, idempotency_key:, now: Time.current)
      @ticket = ticket
      @actor = actor
      @asking_amount_minor = asking_amount_minor
      @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      @now = now.to_time.utc
    rescue ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(error(:invalid_idempotency_key, :unprocessable_entity)) if @initialization_error
      return failure(error(:asking_amount_invalid, :unprocessable_entity)) unless positive_integer?(@asking_amount_minor)

      outcome = nil
      Ticketing::Ticket.transaction do
        ticket = load_ticket
        locked_listings = lock_related_rows(ticket)
        existing = locked_listings.find { |listing| listing.idempotency_key == @idempotency_key.to_s } ||
          ResaleListing.lock.find_by(idempotency_key: @idempotency_key.to_s)

        if existing
          outcome = replay_or_conflict(existing, ticket)
          next
        end

        eligibility = verify_eligibility(ticket, locked_listings)
        if eligibility.failure?
          outcome = eligibility
          next
        end

        listing = build_listing(ticket, eligibility.value)
        listing.save!
        record_activation!(listing)
        publish_activation!(listing)
        outcome = success(listing)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(error(:ticket_not_found, :not_found))
    rescue ActiveRecord::RecordNotUnique
      failure(error(:listing_already_open, :conflict))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:listing_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :ticket, :actor, :asking_amount_minor, :idempotency_key, :now

    def load_ticket
      Ticketing::Ticket.includes(
        :event,
        :owner_user,
        :revocation,
        current_acquisition_order_item: :order,
        registration: :consent_requirements,
        current_credential_generation: :credentials,
        admission_slots: :assigned_user,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).lock.find(ticket.id)
    end

    def lock_related_rows(locked_ticket)
      Ticketing::CredentialGeneration.where(ticket_id: locked_ticket.id).lock.load
      Ticketing::AdmissionSlot.where(ticket_id: locked_ticket.id).lock.load
      Ticketing::AdmissionUse
        .joins(:admission_slot)
        .where(ticketing_admission_slots: { ticket_id: locked_ticket.id })
        .lock
        .load
      Ticketing::TicketSuspension.where(ticket_id: locked_ticket.id).lock.load
      Ticketing::TicketTransfer.where(ticket_id: locked_ticket.id).lock.load
      Ticketing::CredentialClaim
        .joins(credential: :credential_generation)
        .where(ticketing_credential_generations: { ticket_id: locked_ticket.id })
        .lock
        .load
      Orders::RefundItem.where(ticket_id: locked_ticket.id).lock.load
      ResaleListing.where(ticket_id: locked_ticket.id).lock.load
    end

    def verify_eligibility(locked_ticket, locked_listings)
      return failure(error(:listing_forbidden, :forbidden)) unless owner?
      return failure(error(:ticket_not_active, :conflict)) unless locked_ticket.status == "active"
      return failure(error(:package_dead, :conflict)) if locked_ticket.package_dead?
      return failure(error(:package_suspended, :conflict)) if suspended?(locked_ticket)

      ticket_type = locked_ticket.event_product&.ticket_type
      return failure(error(:resale_disabled, :conflict)) unless ticket_type&.resale_enabled
      return failure(error(:paid_acquisition_required, :conflict)) unless paid_acquisition?(locked_ticket)
      return failure(error(:currency_mismatch, :conflict)) unless acquisition_currency_matches?(locked_ticket)
      return failure(error(:group_mode_required, :conflict)) unless group_mode?(locked_ticket)
      return failure(error(:package_already_used, :conflict)) if active_admission_use?(locked_ticket)
      return failure(error(:stream_usage_unavailable, :conflict)) if stream_access?(locked_ticket)
      return failure(error(:active_refund, :conflict)) if active_refund?(locked_ticket)
      return failure(error(:pending_transfer, :conflict)) if pending_transfer?(locked_ticket)
      return failure(error(:active_claim, :conflict)) if active_claim?(locked_ticket)
      return failure(error(:listing_already_open, :conflict)) if locked_listings.any?(&:open?)
      return failure(error(:resale_count_exhausted, :conflict)) if
        locked_ticket.completed_resale_count >= ticket_type.max_completed_resales

      cutoff = resale_cutoff_at(locked_ticket, ticket_type)
      return failure(error(:resale_schedule_unavailable, :conflict)) unless cutoff
      return failure(error(:resale_cutoff_passed, :conflict)) unless now < cutoff

      cap_result = CalculatePriceCap.call(
        cap_type: ticket_type.resale_price_cap_type,
        acquisition_product_value_minor: locked_ticket.current_acquisition_product_value_minor,
        fixed_cap_minor: ticket_type.resale_fixed_cap_minor,
        percentage_cap_bps: ticket_type.resale_percentage_cap_bps
      )
      return failure(cap_result.error) if cap_result.failure?
      return failure(error(:asking_amount_exceeds_cap, :unprocessable_entity)) if
        asking_amount_minor > cap_result.value.calculated_cap_minor

      commercial_result = ResolveResaleCharge.call(
        context: commercial_context(locked_ticket),
        gross_amount_minor: asking_amount_minor
      )
      return failure(commercial_result.error) if commercial_result.failure?

      resale_component = commercial_result.value.component_results.find do |component|
        component.component_type == "resale_platform_fee"
      end
      component = Commercial::FeeComponent.find_by(
        id: resale_component&.component_id,
        fee_schedule_version_id: resale_component&.version_id
      )
      version = Commercial::FeeScheduleVersion.find_by(id: resale_component&.version_id)
      return failure(error(:commercial_terms_unavailable, :unprocessable_entity)) unless component && version

      success(
        ticket_type:,
        cutoff:,
        cap: cap_result.value,
        commercial_component: component,
        commercial_version: version
      )
    end

    def build_listing(locked_ticket, eligibility)
      cap = eligibility.fetch(:cap)
      ResaleListing.new(
        event: locked_ticket.event,
        ticket: locked_ticket,
        ticket_type: eligibility.fetch(:ticket_type),
        seller_user: locked_ticket.owner_user,
        status: "active",
        asking_amount_minor:,
        currency: locked_ticket.event.currency,
        seller_acquisition_product_value_minor: locked_ticket.current_acquisition_product_value_minor,
        cap_type_snapshot: cap.cap_type,
        fixed_cap_minor_snapshot: cap.fixed_cap_minor,
        percentage_cap_bps_snapshot: cap.percentage_cap_bps,
        calculated_cap_minor: cap.calculated_cap_minor,
        resale_count_before: locked_ticket.completed_resale_count,
        max_completed_resales_snapshot: eligibility.fetch(:ticket_type).max_completed_resales,
        resale_cutoff_at: eligibility.fetch(:cutoff),
        commercial_fee_component: eligibility.fetch(:commercial_component),
        commercial_fee_schedule_version: eligibility.fetch(:commercial_version),
        idempotency_key: idempotency_key.to_s,
        activated_at: now
      )
    end

    def replay_or_conflict(existing, locked_ticket)
      return failure(error(:idempotency_conflict, :conflict)) unless
        existing.ticket_id == locked_ticket.id &&
        existing.seller_user_id == locked_ticket.owner_user_id &&
        existing.asking_amount_minor == asking_amount_minor

      success(existing)
    end

    def owner?
      actor.is_a?(Core::User) && ticket.owner_user_id == actor.id
    end

    def paid_acquisition?(locked_ticket)
      PAID_ACQUISITION_TYPES.include?(locked_ticket.current_acquisition_type) &&
        locked_ticket.current_acquisition_product_value_minor.to_i.positive? &&
        locked_ticket.current_acquisition_order_item_id.present? &&
        locked_ticket.current_acquisition_order_item&.fulfilled? &&
        locked_ticket.current_acquisition_order_item.order.paid?
    end

    def acquisition_currency_matches?(locked_ticket)
      locked_ticket.current_acquisition_currency == locked_ticket.event.currency
    end

    def group_mode?(locked_ticket)
      generation = locked_ticket.current_credential_generation
      locked_ticket.credential_mode == "group" && generation&.status == "active" && generation.mode == "group"
    end

    def suspended?(locked_ticket)
      locked_ticket.status == "suspended" || locked_ticket.package_suspended? ||
        Ticketing::TicketSuspension.where(ticket_id: locked_ticket.id, status: "active").exists?
    end

    def active_admission_use?(locked_ticket)
      Ticketing::AdmissionUse
        .joins(:admission_slot)
        .where(ticketing_admission_slots: { ticket_id: locked_ticket.id })
        .where.not(id: Ticketing::AdmissionUseReversal.select(:admission_use_id))
        .exists?
    end

    def stream_access?(locked_ticket)
      locked_ticket.event_product.product_accesses.any?(&:stream?)
    end

    def pending_transfer?(locked_ticket)
      Ticketing::TicketTransfer.where(ticket_id: locked_ticket.id, status: "pending").exists?
    end

    def active_claim?(locked_ticket)
      Ticketing::CredentialClaim
        .joins(credential: :credential_generation)
        .where(ticketing_credential_generations: { ticket_id: locked_ticket.id }, status: ACTIVE_CLAIM_STATUSES)
        .exists?
    end

    def active_refund?(locked_ticket)
      Orders::RefundItem
        .joins(:refund)
        .where(ticket_id: locked_ticket.id, orders_refunds: { status: ACTIVE_REFUND_STATUSES })
        .exists?
    end

    def resale_cutoff_at(locked_ticket, ticket_type)
      accesses = locked_ticket.event_product.product_accesses
      if ticket_type.date_selection == "choose_one" && locked_ticket.registration&.selected_event_date_id
        accesses = accesses.select { |access| access.event_date_id == locked_ticket.registration.selected_event_date_id }
      end
      event_date = accesses.reject { |access| access.event_date.status == "cancelled" }.min_by { |access| access.event_date.starts_at }
      event_date&.event_date&.starts_at&.-(ticket_type.resale_cutoff_seconds_before_start)
    end

    def commercial_context(locked_ticket)
      value = asking_amount_minor
      Commercial::Resolution::Context.new(
        organization_id: locked_ticket.event.organization_id,
        event_id: locked_ticket.event_id,
        event_product_id: locked_ticket.event_product_id,
        product_type: locked_ticket.event_product.type,
        sale_context: "resale",
        sales_channel: "resale",
        currency: locked_ticket.event.currency,
        settlement_currency: locked_ticket.event.currency,
        quoted_at: now,
        item_face_value_minor: value,
        item_net_value_after_organizer_promotion_minor: value,
        eligible_order_subtotal_minor: value,
        resale_acquisition_amount_minor: value,
        accepted_paid_units: 0,
        accepted_gross_minor: 0,
        organizer_payer_selections: {}
      )
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def record_activation!(listing)
      audit = Core::Audit::Record.call(
        audit_key: "marketplace-resale-listing-activated-#{listing.id}",
        action: "marketplace.resale_listing.activated",
        auditable_type: listing.class.name,
        auditable_id: listing.id,
        actor_type: actor.class.name,
        actor_id: actor.id,
        audited_changes: { status: "active" },
        metadata: { event_id: listing.event_id, ticket_id: listing.ticket_id }
      )
      raise audit.error if audit.failure?
    end

    def publish_activation!(listing)
      outbox = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_listing.activated",
        aggregate: listing,
        payload: { listing_id: listing.id, event_id: listing.event_id, ticket_id: listing.ticket_id },
        idempotency_key: "marketplace-resale-listing-activated-#{listing.id}"
      )
      raise outbox.error if outbox.failure?
    end

    def error(code, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"),
        code:,
        status:,
        errors:
      )
    end
  end
end
