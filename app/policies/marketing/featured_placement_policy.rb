# frozen_string_literal: true

module Marketing
  class FeaturedPlacementPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id event_id status surface starts_at ends_at duration_seconds offer_code offer_version daily_rate_minor
      amount_minor currency terms_version created_at updated_at
    ].freeze

    def manage? = organization_owner_or_admin?

    def index? = manage?

    def show? = organization_owner_or_admin?

    def create? = manage?

    def cancel? = organization_owner_or_admin?

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      cancel: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      manage: { default: { fields: [], include: [] }, admin: { fields: [], include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        scope.where(organization_id: Organizations::Membership.active.where(user:, role: %w[owner admin]).select(:organization_id))
      end
    end

    private

    def organization_owner_or_admin?
      return false unless user
      return true if user.super_admin?

      organization_id = record.respond_to?(:organization_id) ? record.organization_id : record.event&.organization_id
      Organizations::Membership.active.exists?(user_id: user.id, organization_id:, role: %w[owner admin])
    end
  end
end
