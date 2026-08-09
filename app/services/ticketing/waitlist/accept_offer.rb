  # frozen_string_literal: true

  module Ticketing
    module Waitlist
      # Accepts an offer only for the verified registrant. Free offers commit the
      # held capacity immediately; paid offers retain the hold and return to order
      # payment without inventing a cash path.
      class AcceptOffer < Core::BaseService
      include Support

      def initialize(registration:, actor:, idempotency_key:)
        @registration = registration
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        audit_key = waitlist_audit_key("offer_accepted", registration, idempotency_key)
        replay = waitlist_replay(audit_key)
        return success(replay) if replay

        accepted = Ticketing::Registration.transaction do
          locked = Ticketing::Registration.lock
            .includes(:event, :user, :consent_requirements, ticket_type: :event_product)
            .find(registration.id)
          halt(waitlist_error("offer_acceptance_unauthorized")) unless buyer_actor?(locked, actor)
          halt(waitlist_error("registration_not_offered")) unless locked.status == "offered"
          halt(waitlist_error("offer_expired")) if locked.offer_expires_at <= Time.current
          halt(waitlist_error("required_buyer_consent_missing")) unless required_buyer_consents_complete?(locked)

          if free_product?(locked)
            unwrap(Ticketing::Registrations::ConfirmFree.call(
              registration: locked,
              actor:,
              idempotency_key: "#{idempotency_key}:confirmation"
            ))
          else
            locked.update!(
              status: "pending_payment",
              waitlisted_at: nil,
              offered_at: nil,
              offer_expires_at: nil,
              next_action_snapshot: "requires_order"
            )
          end
          waitlist_audit!(
            action: "offer_accepted",
            audit_key:,
            registration: locked,
            actor:,
            audited_changes: { status: [ "offered", locked.status ] }
          )
          locked
        end

        success(accepted)
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
