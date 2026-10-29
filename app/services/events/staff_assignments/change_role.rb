# frozen_string_literal: true

module Events
  module StaffAssignments
    class ChangeRole < Core::BaseService
      def initialize(assignment:, actor:, role:)
        @assignment = assignment
        @actor = actor
        @role = role
      end

      def call
        return role_error unless Events::EventStaffAssignment::ROLES.include?(role.to_s)
        return permission_error unless Events::AuthorizationResolver.can_assign?(actor, assignment.event, role)

        Events::Event.transaction do
          Events::Event.lock.find(assignment.event_id)
          assignment.lock!
          if general_role?(role) && Events::EventStaffAssignment.active_general_role_conflict?(
            event_id: assignment.event_id,
            user_id: assignment.user_id,
            except_id: assignment.id
          )
            return role_change_required
          end

          previous = assignment.role
          assignment.update!(role:)
          assignment.record_audit!(
            "event.staff.role_changed",
            actor:,
            audited_changes: { role: { old: previous, new: role } }
          )
          success(assignment)
        end
      rescue ActiveRecord::RecordNotUnique
        role_change_required
      end

      private

      attr_reader :assignment, :actor, :role

      def general_role?(value)
        Events::EventStaffAssignment::GENERAL_ROLES.include?(value.to_s)
      end

      def role_change_required
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.staff_assignment_role_change_required"),
          code: "staff_assignment_role_change_required",
          status: :conflict
        )
      end

      def role_error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invalid_role"),
          code: "invalid_role",
          status: :unprocessable_entity
        )
      end

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "forbidden",
          status: :forbidden
        )
      end
    end
  end
end
