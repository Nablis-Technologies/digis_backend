# frozen_string_literal: true

module Admin
  module Messaging
    # Authorizes quota inspection and explicitly audited quota changes.
    class CampaignVolumePolicyPolicy < Core::ApplicationPolicy
      FIELDS = %i[
        id organization_id channel timezone daily_limit monthly_limit active updated_by_id created_at updated_at
      ].freeze

      def index? = allowed?(:index)
      def show? = allowed?(:show)
      def update? = allowed?(:update)

      VISIBILITY = %i[index show update].to_h do |action|
        [ action, { admin: { fields: FIELDS, include: [] }, default: { fields: [], include: [] } } ]
      end.freeze

      class Scope < Core::ApplicationPolicy::Scope
        def resolve
          return scope.none unless user
          return scope.all if user.super_admin?
          return scope.all if user.has_any_permission?(
            "messaging_campaign_volume_policy.index", "messaging_campaign_volume_policy.show"
          )

          scope.none
        end
      end

      private

      def allowed?(action)
        user&.super_admin? || user&.has_permission?("messaging_campaign_volume_policy.#{action}")
      end
    end
  end
end
