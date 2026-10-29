# frozen_string_literal: true

module Admin
  module Messaging
    # Controls platform-admin management of reusable global campaign templates.
    class CampaignTemplatePolicy < Core::ApplicationPolicy
      FIELDS = %i[id organization_id created_by_id name channel status metadata created_at updated_at].freeze

      def index? = allowed?(:index)
      def show? = allowed?(:show)
      def create? = allowed?(:create)
      def update? = allowed?(:update)

      VISIBILITY = %i[index show create update].to_h do |action|
        [ action, { admin: { fields: FIELDS, include: [] }, default: { fields: [], include: [] } } ]
      end.freeze

      class Scope < Core::ApplicationPolicy::Scope
        def resolve
          return scope.none unless user
          return scope.all if user.super_admin?
          return scope.all if user.has_any_permission?(
            "messaging_campaign_template.index", "messaging_campaign_template.show"
          )

          scope.none
        end
      end

      private

      def allowed?(action)
        user&.super_admin? || user&.has_permission?("messaging_campaign_template.#{action}")
      end
    end
  end
end
