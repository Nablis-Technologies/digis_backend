# frozen_string_literal: true

module Commercial
  module Assignments
    # Records minimal evidence for an externally accepted mutual agreement.
    class RecordExternalAcceptance < Core::BaseService
      def initialize(assignment:, actor:, external_reference:, accepted_at: nil)
        @assignment = assignment
        @actor = actor
        @external_reference = external_reference.to_s.strip
        @accepted_at = accepted_at || Time.current
      end

      def call
        return failure_for(:external_reference_required, "external_reference_required") if external_reference.blank?
        return failure_for(:assignment_type_not_mutual, "assignment_type_not_mutual") unless assignment.mutual_agreement?

        assignment.class.transaction do
          assignment.with_lock do
            if assignment.external_reference.present?
              return success(assignment) if assignment.external_reference == external_reference

              return failure_for(:external_reference_conflict, "external_reference_conflict")
            end

            assignment.external_reference = external_reference
            assignment.external_accepted_by = actor
            assignment.external_accepted_at = accepted_at
            assignment.status = "pending_approval" if %w[draft pending_acceptance].include?(assignment.status)
            assignment.save!
            record_audit
            success(assignment)
          end
        end
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.assignments.errors.invalid_assignment"),
            code: "invalid_assignment", status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :assignment, :actor, :external_reference, :accepted_at

      def failure_for(key, code)
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.assignments.errors.#{key}"),
            code:, status: :unprocessable_entity
          )
        )
      end

      def record_audit
        Core::Audit::Record.call(
          audit_key: "commercial-assignment-external-acceptance-#{assignment.id}",
          action: "commercial.assignment.external_acceptance_recorded",
          auditable_type: "Commercial::Assignment",
          auditable_id: assignment.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: {
            "status" => assignment.status,
            "external_reference" => assignment.external_reference,
            "external_accepted_by_id" => assignment.external_accepted_by_id,
            "external_accepted_at" => assignment.external_accepted_at
          }
        )
      end
    end
  end
end
