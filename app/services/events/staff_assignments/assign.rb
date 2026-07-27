# frozen_string_literal: true

module Events
  module StaffAssignments
    class Assign < Core::BaseService
      def initialize(event:, actor:, user:, organization:, role:)
        @event = event
        @actor = actor
        @user = user
        @organization = organization
        @role = role
      end

      def call
        return role_error unless Events::EventStaffAssignment::ROLES.include?(role.to_s)
        return permission_error unless Events::AuthorizationResolver.can_assign?(actor, event, role)

        Events::Event.transaction do
          event.lock!
          return duplicate_error if Events::EventStaffAssignment.exists?(event:, user:, role:)

          assignment = Events::EventStaffAssignment.create!(
            event:,
            user:,
            organization:,
            role:,
            status: "active"
          )
          assignment.record_audit!(
            "event.staff.assigned",
            actor:,
            audited_changes: { user_id: user.id, role: }
          )
          success(assignment)
        end
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.assign"),
          code: "invalid_assignment",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :event, :actor, :user, :organization, :role

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

      def duplicate_error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.duplicate_assignment"),
          code: "duplicate_assignment",
          status: :unprocessable_entity
        )
      end
    end
  end
end
