# frozen_string_literal: true

module Events
  module StaffAssignments
    class Activate < Core::BaseService
      def initialize(assignment:, actor:)
        @assignment = assignment
        @actor = actor
      end

      def call
        return permission_error unless Events::AuthorizationResolver.can_assign?(actor, assignment.event, assignment.role)

        Events::Event.transaction do
          Events::Event.lock.find(assignment.event_id)
          assignment.lock!
          if Events::EventStaffAssignment::GENERAL_ROLES.include?(assignment.role) &&
              Events::EventStaffAssignment.active_general_role_conflict?(
                event_id: assignment.event_id,
                user_id: assignment.user_id,
                except_id: assignment.id
              )
            return role_change_required
          end

          assignment.update!(status: "active")
          assignment.record_audit!("event.staff.activated", actor:)
          success(assignment)
        end
      rescue ActiveRecord::RecordNotUnique
        role_change_required
      end

      private

      attr_reader :assignment, :actor

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "forbidden",
          status: :forbidden
        )
      end

      def role_change_required
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.staff_assignment_role_change_required"),
          code: "staff_assignment_role_change_required",
          status: :conflict
        )
      end
    end
  end
end
