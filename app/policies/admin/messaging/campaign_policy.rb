# frozen_string_literal: true

module Admin
  module Messaging
    # Platform-admin read boundary for campaign operations. The admin API
    # intentionally exposes the same safe campaign projection as organizers.
    class CampaignPolicy < Core::ApplicationPolicy
      FIELDS = %i[
        id organization_id created_by_id event_id name channel status timezone launch_version
        send_at launched_at completed_at canceled_at variables quoted_quantity quoted_unit_price_minor quoted_rate_version_id
        quoted_at quote_expires_at audience_status audience_total_count audience_eligible_quantity
        created_at updated_at
      ].freeze

      def index? = allowed?(:index)
      def show? = allowed?(:show)

      VISIBILITY = {
        index: { admin: { fields: FIELDS, include: [] }, default: { fields: [], include: [] } },
        show: { admin: { fields: FIELDS, include: [] }, default: { fields: [], include: [] } }
      }.freeze

      class Scope < Core::ApplicationPolicy::Scope
        def resolve
          return scope.none unless user
          return scope.all if user.super_admin?
          return scope.all if user.has_any_permission?("messaging_campaign.index", "messaging_campaign.show")

          scope.none
        end
      end

      private

      def allowed?(action)
        user&.super_admin? || user&.has_permission?("messaging_campaign.#{action}")
      end
    end
  end
end
