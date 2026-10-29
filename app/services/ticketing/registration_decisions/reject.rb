# frozen_string_literal: true

module Ticketing
  module RegistrationDecisions
    # Replaces a pending approval with a reasoned, auditable rejection. The
    # effective approval and rejection timestamps remain mutually exclusive.
    class Reject < Core::BaseService
      include Support

      def initialize(registration:, actor:, reason: nil, idempotency_key:)
        @registration = registration
        @actor = actor
        @reason = reason
        @idempotency_key = idempotency_key
      end

      def call
        audit_key = decision_audit_key("rejected", registration, idempotency_key)
        replay = replayed_registration(audit_key)
        return success(replay) if replay

        rejected = Ticketing::Registration.transaction do
          locked = Ticketing::Registration.lock
            .includes(:event, :user, ticket_type: :event_product)
            .find(registration.id)
          halt("reviewer_unauthorized") unless reviewer_authorized?(locked, actor)
          halt("registration_not_rejectable") unless locked.status == "pending_approval"

          now = Time.current
          locked.update!(
            status: "rejected",
            approved_at: nil,
            rejected_at: now,
            reviewed_by: actor,
            decision_reason: reason,
            next_action_snapshot: nil
          )
          unwrap(Ticketing::Registrations::AudienceProof::Release.call(
            registration: locked,
            reason: "organizer_rejected",
            transition_key: audit_key,
            at: now
          ))
          record_decision_audit!(
            action: "rejected",
            audit_key:,
            registration: locked,
            actor:,
            audited_changes: { status: [ "pending_approval", "rejected" ], decision_reason: reason }
          )
          unwrap(Core::Outbox::Publish.call(
            topic: "ticketing",
            event_type: "ticketing.registration.rejected",
            aggregate: locked,
            payload: { registration_id: locked.id },
            idempotency_key: "#{audit_key}-notification"
          ))
          locked
        end

        success(rejected)
      rescue Ticketing::Registrations::Support::Halt => error
        error.result
      rescue ArgumentError
        failure(decision_error("invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.registration_workflows.errors.invalid_registration"),
            code: "invalid_registration",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :registration, :actor, :reason, :idempotency_key
    end
  end
end
