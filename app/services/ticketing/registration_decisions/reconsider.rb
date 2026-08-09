# frozen_string_literal: true

module Ticketing
  module RegistrationDecisions
    class Reconsider < Core::BaseService
      include Support

      def initialize(registration:, actor:, decision:, reason: nil, idempotency_key:)
        @registration = registration
        @actor = actor
        @decision = decision.to_s
        @reason = reason
        @idempotency_key = idempotency_key
      end

      def call
        audit_key = decision_audit_key("reconsidered", registration, idempotency_key)
        replay = replayed_registration(audit_key)
        return success(replay) if replay

        reconsidered = Ticketing::Registration.transaction do
          locked = Ticketing::Registration.lock
            .includes(:event, :user, :consent_requirements, ticket_type: :event_product)
            .find(registration.id)
          halt("reviewer_unauthorized") unless reviewer_authorized?(locked, actor)
          halt("invalid_reconsideration_decision") unless decision.in?(%w[approve reject])
          halt("registration_not_reconsiderable") unless locked.status == "rejected"

          previous_status = locked.status
          now = Time.current
          if decision == "approve"
            locked.update!(
              status: "pending_payment",
              approved_at: now,
              rejected_at: nil,
              reviewed_by: actor,
              decision_reason: reason,
              next_action_snapshot: free_product?(locked) ? "requires_confirmation" : "requires_order"
            )
            if free_product?(locked)
              unwrap(reserve_capacity!(locked, idempotency_key: "#{idempotency_key}:approval"))
              unwrap(Ticketing::Registrations::ConfirmFree.call(
                registration: locked,
                actor:,
                idempotency_key: "#{idempotency_key}:confirmation"
              ))
            end
          else
            locked.update!(
              status: "rejected",
              approved_at: nil,
              rejected_at: now,
              reviewed_by: actor,
              decision_reason: reason,
              next_action_snapshot: nil
            )
          end

          record_decision_audit!(
            action: "reconsidered",
            audit_key:,
            registration: locked,
            actor:,
            audited_changes: {
              status: [ previous_status, locked.status ],
              decision:,
              decision_reason: reason
            },
            metadata: { previous_decision: "rejected" }
          )
          locked
        end

        success(reconsidered)
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

      attr_reader :registration, :actor, :decision, :reason, :idempotency_key
    end
  end
end
