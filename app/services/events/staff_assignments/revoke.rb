# frozen_string_literal: true

module Events
  module StaffAssignments
    class Revoke < Core::BaseService
      def initialize(assignment:, actor:)
        @assignment = assignment
        @actor = actor
      end

      def call
        return permission_error unless Events::AuthorizationResolver.can_assign?(actor, assignment.event, assignment.role)

        Events::Event.transaction do
          assignment.lock!
          assignment.update!(status: "revoked")
          assignment.record_audit!("event.staff.revoked", actor:)
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
