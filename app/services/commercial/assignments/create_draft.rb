# frozen_string_literal: true

module Commercial
  module Assignments
    # Creates a draft assignment and computes its bounded approval risk.
    class CreateDraft < Core::BaseService
      def initialize(organization:, actor:, fee_schedule_version:, assignment_type:, reason:,
                     effective_from:, event: nil, program: nil, effective_until: nil,
                     baseline_resolution_digest: nil)
        @organization = organization
        @actor = actor
        @fee_schedule_version = fee_schedule_version
        @assignment_type = assignment_type.to_s
        @reason = reason.to_s.strip
        @effective_from = effective_from
        @effective_until = effective_until
        @event = event
        @program = program
        @baseline_resolution_digest = baseline_resolution_digest
      end

      def call
        return failure_for(:invalid_assignment_type, "invalid_assignment_type") unless assignment_type.in?(Commercial::Assignment::ASSIGNMENT_TYPES)
        return failure_for(:event_organization_mismatch, "event_organization_mismatch") if event && event.organization_id != organization.id
        if platform_grant? && baseline_resolution_digest.present? && !valid_digest?
          return failure_for(:invalid_baseline_digest, "invalid_baseline_digest")
        end
        return failure_for(:baseline_required, "baseline_digest_required") if platform_grant? && !valid_digest?

        assignment = build_assignment
        return failure_for_model(assignment) unless assignment.valid?

        Commercial::Assignment.transaction do
          assignment.save!
          record_audit(assignment)
        end
        success(assignment)
      rescue ActiveRecord::RecordInvalid => error
        failure_for_model(error.record)
      end

      private

      attr_reader :organization, :actor, :fee_schedule_version, :assignment_type,
                  :reason, :effective_from, :effective_until, :event, :program,
                  :baseline_resolution_digest

      def build_assignment
        Commercial::Assignment.new(
          organization:,
          event:,
          fee_schedule_version:,
          program:,
          assignment_type:,
          status: mutual_agreement? ? "pending_acceptance" : "draft",
          reason:,
          effective_from:,
          effective_until:,
          risk_level: calculated_risk_level,
          baseline_resolution_digest:,
          created_by: actor
        )
      end

      def calculated_risk_level
        return "high" if mutual_agreement?
        return "high" if platform_grant? && effective_until.blank?
        return "medium" if platform_grant?

        "low"
      end

      def platform_grant?
        assignment_type == "platform_grant"
      end

      def mutual_agreement?
        assignment_type == "mutual_agreement"
      end

      def valid_digest?
        baseline_resolution_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
      end

      def failure_for(key, code)
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.assignments.errors.#{key}"),
            code:, status: :unprocessable_entity
          )
        )
      end

      def failure_for_model(assignment)
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.assignments.errors.invalid_assignment"),
            code: "invalid_assignment", status: :unprocessable_entity,
            errors: assignment.errors.to_hash
          )
        )
      end

      def record_audit(assignment)
        Core::Audit::Record.call(
          audit_key: "commercial-assignment-created-#{assignment.id}",
          action: "commercial.assignment.created",
          auditable_type: "Commercial::Assignment",
          auditable_id: assignment.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: assignment.attributes.slice(
            "organization_id", "event_id", "fee_schedule_version_id", "program_id",
            "assignment_type", "status", "reason", "effective_from", "effective_until",
            "risk_level", "baseline_resolution_digest"
          )
        )
      end
    end
  end
end
