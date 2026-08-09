  # frozen_string_literal: true

  module Ticketing
    module Waitlist
      # Places the existing registration in the ordered queue by changing its
      # state and timestamp; it never creates a second waitlist record.
      class Enqueue < Core::BaseService
      include Support

      def initialize(registration:, actor: nil, idempotency_key:)
        @registration = registration
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        audit_key = waitlist_audit_key("enqueued", registration, idempotency_key)
        replay = waitlist_replay(audit_key)
        return success(replay) if replay

        queued = Ticketing::Registration.transaction do
          locked = Ticketing::Registration.lock
            .includes(:event, :user, ticket_type: :event_product)
            .find(registration.id)
          halt(waitlist_error("waitlist_disabled")) unless locked.ticket_type.waitlist_enabled?
          halt(waitlist_error("registration_not_waitlistable")) if locked.status.in?(%w[rejected confirmed cancelled expired])
          halt(waitlist_error("registration_not_waitlistable")) unless locked.status.in?(%w[pending_payment pending_approval waitlisted])

          now = Time.current
          locked.update!(
            status: "waitlisted",
            approved_at: locked.approved_at || (now if locked.ticket_type.approval_mode == "automatic"),
            waitlisted_at: locked.waitlisted_at || now,
            offered_at: nil,
            offer_expires_at: nil,
            next_action_snapshot: nil
          )
          waitlist_audit!(
            action: "waitlisted",
            audit_key:,
            registration: locked,
            actor:,
            audited_changes: { status: [ registration.status, "waitlisted" ] }
          )
          locked
        end

        success(queued)
      rescue Ticketing::Registrations::Support::Halt => error
        error.result
      rescue ArgumentError
        failure(waitlist_error("invalid_idempotency_key"))
      end

      private

      attr_reader :registration, :actor, :idempotency_key

      def halt(error)
        fail Ticketing::Registrations::Support::Halt, Core::BaseService::Result.failure(error)
      end
      end
    end
  end
