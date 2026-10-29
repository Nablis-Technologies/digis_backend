# frozen_string_literal: true

module Events
  module StaffAssignments
    # Consumes an internal event-scoped invitation grant. The caller must lock
    # and validate the source invitation; this service owns only the Events row.
    class AssignFromDelegatedGrant < Core::BaseService
      def initialize(event:, organization:, user:, grant:)
        @event = event
        @organization = organization
        @user = user
        @grant = grant
      end

      def call
        return failure(invalid_grant) unless grant&.valid_for?(event:, role: "scanner")
        return failure(invalid_grant) unless organization.id == event.organization_id

        result = nil
        Events::Event.transaction do
          event.lock!
          existing = Events::EventStaffAssignment.find_by(event:, user:, role: "scanner")
          result = existing_assignment(existing) || create_assignment
        end
        result
      rescue ActiveRecord::RecordInvalid => exception
        failure(assignment_error(exception))
      rescue ActiveRecord::RecordNotFound
        failure(invalid_grant)
      end

      private

      attr_reader :event, :organization, :user, :grant

      def existing_assignment(assignment)
        return unless assignment
        return success(assignment) if assignment.active?

        failure(Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.assignment_inactive"),
          code: "assignment_inactive",
          status: :conflict
        ))
      end

      def create_assignment
        assignment = Events::EventStaffAssignment.create!(
          event:,
          user:,
          organization:,
          role: "scanner",
          status: "active"
        )
        assignment.record_audit!(
          "event.staff.assigned_from_grant",
          actor: grantor,
          audited_changes: { user_id: user.id, role: "scanner" },
          metadata: {
            grant_source_type: grant.source_type,
            grant_source_id: grant.source_id,
            grant_issued_at: grant.issued_at.iso8601
          }
        )
        success(assignment)
      end

      def grantor
        @grantor ||= Core::User.find(grant.grantor_id)
      end

      def invalid_grant
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.delegated_grant_invalid"),
          code: "delegated_grant_invalid",
          status: :forbidden
        )
      end

      def assignment_error(exception)
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.assign"),
          code: "invalid_assignment",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        )
      end
    end
  end
end
