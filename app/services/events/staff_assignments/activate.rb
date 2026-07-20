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
          assignment.lock!
          assignment.update!(status: "active")
          assignment.record_audit!("event.staff.activated", actor:)
          success(assignment)
        end
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
    end
  end
end
