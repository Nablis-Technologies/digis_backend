  # frozen_string_literal: true

  module Ticketing
    module Waitlist
      # Releases an expired offer's holds and resets its queue timestamp so the
      # registration returns at the back of the same scoped queue.
      class ExpireOffer < Core::BaseService
      include Support

      def initialize(registration:, idempotency_key:)
        @registration = registration
        @idempotency_key = idempotency_key
      end

      def call
        audit_key = waitlist_audit_key("offer_expired", registration, idempotency_key)
        replay = waitlist_replay(audit_key)
        return success(replay) if replay

        expired = Ticketing::Registration.transaction do
          locked = Ticketing::Registration.lock
            .includes(:event, :user, ticket_type: :event_product)
            .find(registration.id)
          halt(waitlist_error("registration_not_offered")) unless locked.status == "offered"
          halt(waitlist_error("offer_not_expired")) if locked.offer_expires_at > Time.current
          expired_at = locked.offer_expires_at

          unwrap(release_capacity!(locked, idempotency_key: "#{idempotency_key}:release"))
          locked.update!(
            status: "waitlisted",
            waitlisted_at: Time.current,
            offered_at: nil,
            offer_expires_at: nil,
            next_action_snapshot: nil
          )
          waitlist_audit!(
            action: "waitlist_offer_expired",
            audit_key:,
            registration: locked,
            actor: nil,
            audited_changes: { status: [ "offered", "waitlisted" ] }
          )
          unwrap(Core::Outbox::Publish.call(
            topic: "ticketing",
            event_type: "ticketing.registration.waitlist_offer_expired",
            aggregate: locked,
            payload: {
              registration_id: locked.id,
              event_id: locked.event_id,
              offer_expires_at: expired_at.iso8601
            },
            idempotency_key: "#{audit_key}-notification"
          ))
          locked
        end

        success(expired)
      rescue Ticketing::Registrations::Support::Halt => error
        error.result
      rescue ArgumentError
        failure(waitlist_error("invalid_idempotency_key"))
      end

      private

      attr_reader :registration, :idempotency_key

      def halt(error)
        fail Ticketing::Registrations::Support::Halt, Core::BaseService::Result.failure(error)
      end
      end
    end
  end
