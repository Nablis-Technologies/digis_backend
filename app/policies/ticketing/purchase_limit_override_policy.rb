# frozen_string_literal: true

module Ticketing
  # Only platform administrators and event catalogue managers may grant a
  # registration-specific purchase-limit exception.
  class PurchaseLimitOverridePolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id registration_id ticket_type_id user_id scope_event_date_id additional_packages
      approved_by_id reason_code created_at updated_at
    ].freeze

    def create?
      return false unless user && record&.event

      Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end

    VISIBILITY = {
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        event_ids = Events::AuthorizationResolver.manageable_catalog_events(user).select(:id)
        scope.joins(:registration).where(ticketing_registrations: { event_id: event_ids })
      end
    end
  end
end
