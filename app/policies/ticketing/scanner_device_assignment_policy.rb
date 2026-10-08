# frozen_string_literal: true

module Ticketing
  # Authorizes the signed-in operator half of scanner authentication. The
  # scanner token is checked separately by Scanners::Authenticate.
  class ScannerDeviceAssignmentPolicy < Core::ApplicationPolicy
    SCANNER_ROLES = %i[super_admin admin owner manager scanner].freeze
    SAFE_FIELDS = %i[
      id event_id event_staff_assignment_id scanner_device_id assigned_by_id status starts_at ends_at
      last_revocation_version last_attendee_index_version last_schedule_version
      last_admission_use_reversal_version last_synced_at created_at updated_at
    ].freeze

    def show?
      Events::AuthorizationResolver.role_for(user, record.event).in?(SCANNER_ROLES)
    end

    def create?
      Events::AuthorizationResolver.can_assign?(user, record.event, "scanner")
    end

    alias update? create?
    alias destroy? create?

    VISIBILITY = %i[index show create update destroy].index_with do
      {
        default: { fields: SAFE_FIELDS, include: [] },
        admin: { fields: SAFE_FIELDS, include: [] }
      }
    end.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

        scope.where(event_id: Events::EventPolicy::Scope.new(user, Events::Event).resolve.select(:id))
      end
    end
  end
end
