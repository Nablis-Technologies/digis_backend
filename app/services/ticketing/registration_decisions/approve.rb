# frozen_string_literal: true

module Ticketing
  module RegistrationDecisions
    # Applies an approval under the registration lock. Automatic products do
    # not need a reviewer; manual products retain the reviewer on the current
    # decision, and free approvals continue through the normal confirmation path.
    class Approve < Core::BaseService
      include Support

      def initialize(registration:, actor: nil, idempotency_key:)
        @registration = registration
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        audit_key = decision_audit_key("approved", registration, idempotency_key)
        replay = replayed_registration(audit_key)
        return success(replay) if replay

        approved = Ticketing::Registration.transaction do
          locked = Ticketing::Registration.lock
            .includes(:event, :user, :consent_requirements, ticket_type: :event_product)
            .find(registration.id)
          validate_request!(locked)
          previous_status = locked.status
          now = Time.current
          locked.update!(
            approved_at: now,
            rejected_at: nil,
            reviewed_by: actor,
            decision_reason: nil,
            status: "pending_payment",
            next_action_snapshot: "requires_order"
          )

          record_decision_audit!(
            action: "approved",
            audit_key:,
            registration: locked,
            actor:,
            audited_changes: {
              status: [ previous_status, locked.status ],
              approved_at: [ nil, locked.approved_at ]
            }
          )
          locked
        end

        success(approved)
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

      attr_reader :registration, :actor, :idempotency_key

      def validate_request!(locked)
        automatic = locked.ticket_type.approval_mode == "automatic"
        halt("reviewer_unauthorized") if actor.present? && !reviewer_authorized?(locked, actor)
        halt("reviewer_required") if !automatic && actor.blank?
        halt("event_cancelled") if locked.event.status == "cancelled"
        halt("registration_not_approvable") unless locked.status.in?(%w[pending_approval pending_payment])
      end
    end
  end
end
