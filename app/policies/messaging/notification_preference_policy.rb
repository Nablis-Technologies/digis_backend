# frozen_string_literal: true

module Messaging
  # Keeps preference reads and writes bound to the authenticated user. Mandatory
  # in-app channels are enforced by UpdatePreferences, not bypassed by policy.
  class NotificationPreferencePolicy < Core::ApplicationPolicy
    FIELDS = %i[id category channel enabled created_at updated_at].freeze

    def show? = owner?
    def update? = owner?

    VISIBILITY = {
      show: {
        default: { fields: FIELDS, include: [] },
        admin: { fields: FIELDS, include: [] }
      },
      update: {
        default: { fields: FIELDS, include: [] },
        admin: { fields: FIELDS, include: [] }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        scope.where(user_id: user.id)
      end
    end

    private

    def owner?
      user.present? && record.user_id == user.id
    end
  end
end
