# frozen_string_literal: true

module Ticketing
  module Registrations
    # Finishes cleanup after Orders expires a gift with incomplete attendee
    # consent. Ticketing owns the recipient registration, package, credentials,
    # suspension, and purchase-limit transitions.
    class ExpireGiftClaim < Core::BaseService
      include Ticketing::Suspensions::Support

      REVOCATION_REASON = "gift_expired_before_consent".freeze

      def initialize(registration_id:, ticket_id:, at: Time.current)
        @registration_id = registration_id
        @ticket_id = ticket_id
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(expiry_error("gift_claim_expiry_invalid", :bad_request)) if
          @initialization_error || @registration_id.blank? || @ticket_id.blank?

        outcome = nil
        ActiveRecord::Base.transaction do
          ticket = Ticketing::Ticket.includes(:event, :revocation, :ticket_suspensions).lock.find(@ticket_id)
          event = Events::Event.lock.find(ticket.event_id)
          registration = Ticketing::Registration.includes(:user).lock.find(@registration_id)

          if terminal?(ticket, registration)
            outcome = success(ticket)
            next
          end

          invalid = validate(ticket, registration)
          if invalid
            outcome = failure(invalid)
            raise ActiveRecord::Rollback
          end

          generation = active_generation(ticket)
          if generation
            revocation = Ticketing::Revocations::PublishGeneration.call(
              ticket:,
              through_version: generation.version,
              reason: REVOCATION_REASON
            )
            if revocation.failure?
              outcome = revocation
              raise ActiveRecord::Rollback
            end
            revoke_index_entries!(generation, event)
          end

          ticket.reload
          ticket.update!(status: "void") unless ticket.status.in?(%w[void refunded])
          projection = dead_package_projection(ticket, event, generation)
          expire_suspensions!(ticket, projection)
          expire_consent_requirements!(registration)
          registration.update!(status: "expired") unless registration.status == "expired"
          release_purchase_limits!(registration)
          record_expiry!(registration, ticket, event)
          outcome = success(ticket.reload)
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(expiry_error("gift_claim_expiry_invalid", :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(expiry_error("gift_claim_expiry_invalid", :unprocessable_entity, errors: error.record.errors.to_hash))
      rescue Core::Error => error
        failure(error)
      end

      private

      def validate(ticket, registration)
        return expiry_error("gift_claim_expiry_invalid", :conflict) unless
          ticket.registration_id == registration.id && ticket.order_item_id.present? &&
          ticket.event_id == registration.event_id
        return expiry_error("gift_claim_expiry_not_pending", :conflict) unless
          registration.status == "confirmed" && required_consent_pending?(registration)
        return expiry_error("gift_claim_expiry_invalid", :conflict) unless
          ticket.status.in?(%w[active suspended void refunded])

        nil
      end

      def required_consent_pending?(registration)
        Ticketing::RegistrationConsentRequirement.where(
          registration_id: registration.id,
          required: true,
          status: "pending"
        ).exists?
      end

      def terminal?(ticket, registration)
        registration.status == "expired" && ticket.status.in?(%w[void refunded]) && ticket.package_dead?
      end

      def active_generation(ticket)
        Ticketing::CredentialGeneration.lock.find_by(ticket_id: ticket.id, status: "active")
      end

      def revoke_index_entries!(generation, event)
        credentials = Ticketing::Credential.where(credential_generation_id: generation.id).order(:id).lock.to_a
        Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", event.id)
        credentials.each do |credential|
          result = Ticketing::AttendeeIndex::Upsert.call(
            credential:,
            loaded_credential: credential,
            removed: true,
            event:,
            index_lock_held: true
          )
          raise result.error if result.failure?
        end
      end

      def dead_package_projection(ticket, event, generation)
        revocation = Ticketing::Revocation.lock.find_or_initialize_by(ticket_id: ticket.id)
        revocation.event = event if revocation.new_record?
        publish_projection!(
          ticket:,
          event:,
          revocation:,
          is_dead: true,
          is_suspended: false,
          revoked_through_version: generation&.version || ticket.credential_version
        )
        revocation
      end

      def expire_suspensions!(ticket, revocation)
        Ticketing::TicketSuspension.where(ticket_id: ticket.id, status: "active").order(:id).lock.each do |suspension|
          suspension.update!(
            status: "expired",
            resolved_by: nil,
            resolution_reason: "gift_claim_expired",
            resolved_at: @at
          )
          record_transition!(
            suspension:,
            action: "expired",
            actor: nil,
            metadata: { reason: REVOCATION_REASON, revocation_version: revocation.revocation_version }
          )
          publish_transition!(suspension:, ticket:, revocation:, action: "expired", automated: true)
        end
      end

      def release_purchase_limits!(registration)
        allocations = Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id,
          user_id: registration.user_id,
          status: %w[reserved committed]
        )
        return unless allocations.exists?

        result = Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: registration.user,
          reason: "expired",
          idempotency_key: "ticketing-gift-claim-expired-#{registration.id}"
        )
        raise result.error if result.failure?
      end

      def expire_consent_requirements!(registration)
        Ticketing::RegistrationConsentRequirement.where(
          registration_id: registration.id,
          status: "pending"
        ).update_all(status: "expired", expired_at: @at, updated_at: @at)
      end

      def record_expiry!(registration, ticket, event)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-gift-claim-expired-#{registration.id}",
          action: "ticketing.registration.gift_claim_expired",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          audited_changes: { status: [ "confirmed", "expired" ] },
          metadata: { event_id: event.id, ticket_id: ticket.id, reason: REVOCATION_REASON }
        )
        raise result.error if result.failure?
      end

      def expiry_error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.gift_purchases.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
