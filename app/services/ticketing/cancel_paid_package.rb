# frozen_string_literal: true

module Ticketing
  # Coordinates an organizer's paid-package cancellation. Access is suspended
  # before the refund obligation is recorded; only a durable successful refund
  # may revoke the package permanently and resolve the suspension.
  class CancelPaidPackage < Core::BaseService
    include Ticketing::Suspensions::Support

    REFUND_REASON = "organizer_ticket_cancellation".freeze

    def initialize(ticket:, actor: nil, idempotency_key: nil, override_reason: nil, refund: nil)
      @ticket = ticket
      @actor = actor
      @override_reason = override_reason.to_s.strip.presence
      @refund = refund
      @idempotency_key = Core::IdempotencyKey.new(idempotency_key) unless refund
    rescue ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(package_error(:invalid_idempotency_key)) if @initialization_error
      return finalize_refund if @refund

      ticket = load_ticket
      validation = validate_request(ticket)
      return failure(validation) if validation

      suspension = open_or_reuse_suspension(ticket)
      return failure(suspension.error) if suspension.failure?

      record_used_override!(ticket) if used_package?(ticket)
      create_refund(ticket)
    rescue ActiveRecord::RecordNotFound
      failure(package_error(:ticket_not_found, :not_found))
    rescue ActiveRecord::RecordInvalid => error
      failure(package_error(:package_refund_invalid, errors: error.record.errors.to_hash))
    rescue Core::Error => error
      failure(error)
    end

    private

    def load_ticket
      Ticketing::Ticket.includes(
        :event,
        :revocation,
        :ticket_suspensions,
        :admission_slots,
        current_acquisition_order_item: { order: :payments },
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).find(@ticket.id)
    end

    def validate_request(ticket)
      return package_error(:suspension_forbidden, :forbidden) unless authorized_actor?(ticket.event)
      return package_error(:organizer_cancellation_requires_paid_ticket) unless paid_ticket?(ticket)
      return package_error(:package_dead, :conflict) if ticket.package_dead?
      return package_error(:ticket_not_active, :conflict) unless ticket.status == "active"
      return package_error(:event_not_active, :conflict) unless active_event?(ticket.event)

      return unless used_package?(ticket)
      return if platform_override?

      package_error(:package_used, :conflict)
    end

    def open_or_reuse_suspension(ticket)
      existing = ticket.ticket_suspensions.find { |suspension| suspension.status == "active" }
      if existing
        return success(existing) if existing.reason_code == "organizer_cancellation"

        return failure(suspension_error(:suspension_already_active, :conflict))
      end

      result = Ticketing::Suspensions::Open.call(
        ticket:,
        actor: @actor,
        reason_code: "organizer_cancellation",
        review_deadline_at: 30.days.from_now,
        idempotency_key: "ticketing-package-suspension-#{@idempotency_key.digest}"
      )
      return result if result.success?
      return result unless result.error.code == "suspension_already_active"

      active = Ticketing::TicketSuspension.find_by(ticket_id: ticket.id, status: "active")
      return failure(suspension_error(:suspension_already_active, :conflict)) unless active
      return success(active) if active.reason_code == "organizer_cancellation"

      failure(suspension_error(:suspension_already_active, :conflict))
    end

    def create_refund(ticket)
      item = ticket.current_acquisition_order_item
      payment = item.order.payments
        .select { |candidate| candidate.status == "succeeded" && candidate.accepted_at.present? }
        .max_by(&:attempt_number)
      return failure(package_error(:payment_not_found, :conflict)) unless payment

      result = Orders::CreateItemRefund.call(
        payment:,
        order_item: item,
        ticket:,
        quantity: 1,
        reason_code: REFUND_REASON,
        idempotency_key: "ticketing-package-refund-#{ticket.id}-#{@idempotency_key.digest}"
      )
      return failure(result.error) if result.failure?

      success(result.value)
    end

    def finalize_refund
      refund = Orders::Refund.includes(refund_items: :ticket).lock.find(@refund.id)
      return success(refund) if refund.refund_items.empty?
      return failure(package_error(:package_refund_not_succeeded, :conflict)) unless refund.succeeded?

      item = refund.refund_items.find { |refund_item| refund_item.ticket_id.present? && refund_item.event_date_id.nil? }
      return failure(package_error(:package_refund_invalid)) unless item

      outcome = nil
      Ticketing::Ticket.transaction do
        ticket = Ticketing::Ticket.includes(
          :event,
          :revocation,
          :ticket_suspensions,
          :admission_slots,
          event_product: [ :ticket_type, { product_accesses: :event_date } ]
        ).lock.find(item.ticket_id)
        generation = ticket.credential_generations.includes(:credentials).lock.find_by!(status: "active")
        ticket.admission_slots.order(:position).lock.to_a
        Ticketing::AdmissionUse.where(admission_slot_id: ticket.admission_slots.select(:id)).lock.load
        suspension = ticket.ticket_suspensions.lock.find_by!(status: "active")
        Orders::Payment.lock.find(refund.payment_id)
        Orders::Refund.where(payment_id: refund.payment_id).lock.load

        credentials = generation.credentials.to_a
        revoked = Ticketing::Revocations::PublishGeneration.call(
          ticket:,
          through_version: generation.version,
          reason: "package_refunded"
        )
        raise revoked.error if revoked.failure?

        ticket.update!(status: "refunded")
        event = Events::Event.lock.find(ticket.event_id)
        revocation = Ticketing::Revocation.lock.find_or_initialize_by(ticket_id: ticket.id)
        publish_projection!(
          ticket:,
          event:,
          revocation:,
          is_dead: true,
          is_suspended: false,
          revoked_through_version: generation.version
        )
        credentials.each do |credential|
          projection = Ticketing::AttendeeIndex::Upsert.call(credential:, removed: true)
          raise projection.error if projection.failure?
        end

        suspension.update!(
          status: "cancelled_refunded",
          resolved_by: suspension.initiated_by,
          resolution_reason: "refund_succeeded",
          resolved_at: Time.current
        )
        record_transition!(
          suspension:,
          action: "cancelled_refunded",
          actor: nil,
          metadata: { refund_id: refund.id, revocation_version: revocation.revocation_version }
        )
        publish_transition!(suspension:, ticket:, revocation:, action: "cancelled_refunded")
        publication = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.package_refunded",
          aggregate: ticket,
          payload: {
            ticket_id: ticket.id,
            refund_id: refund.id,
            version: generation.version,
            package_dead: true,
            attendee_index_version: event.attendee_index_version
          },
          idempotency_key: "ticketing-package-refunded-#{refund.id}"
        )
        raise publication.error if publication.failure?
        outcome = success(refund)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(package_error(:package_refund_not_found, :not_found))
    rescue ActiveRecord::RecordInvalid => error
      failure(package_error(:package_refund_invalid, errors: error.record.errors.to_hash))
    rescue Core::Error => error
      failure(error)
    end

    def record_used_override!(ticket)
      return unless used_package?(ticket)

      result = Core::Audit::Record.call(
        audit_key: "ticketing-package-refund-used-override-#{ticket.id}-#{@idempotency_key.digest}",
        action: "ticketing.package_refund.used_override",
        auditable_type: ticket.class.name,
        auditable_id: ticket.id,
        actor_type: @actor.class.name,
        actor_id: @actor.id,
        audited_changes: { override_reason: @override_reason },
        metadata: { ticket_id: ticket.id, reason_code: REFUND_REASON }
      )
      raise result.error if result.failure?
    end

    def paid_ticket?(ticket)
      Ticketing::Ticket::PAID_ACQUISITION_TYPES.include?(ticket.current_acquisition_type) &&
        ticket.current_acquisition_product_value_minor.to_i.positive? &&
        ticket.current_acquisition_order_item.present?
    end

    def used_package?(ticket)
      Ticketing::AdmissionUse.joins(:admission_slot).where(
        ticketing_admission_slots: { ticket_id: ticket.id }
      ).exists?
    end

    def platform_override?
      @override_reason.present? && @actor&.super_admin? ||
        @override_reason.present? && @actor&.has_role?("ADMIN") ||
        @override_reason.present? && @actor&.has_role?("CORE_ADMIN")
    end

    def authorized_actor?(event)
      @actor.is_a?(Core::User) && Events::AuthorizationResolver.can_manage_catalog?(@actor, event)
    end

    def active_event?(event)
      !event.status.in?(%w[cancelled completed])
    end

    def package_error(key, status = :unprocessable_entity, errors: nil)
      Core::BusinessError.new(
        I18n.t("ticketing.suspensions.errors.#{key}"), code: key, status:, errors:
      )
    end

    def suspension_error(key, status = :unprocessable_entity)
      Core::BusinessError.new(
        I18n.t("ticketing.suspensions.errors.#{key}"), code: key, status:
      )
    end
  end
end
