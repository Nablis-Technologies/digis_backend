# frozen_string_literal: true

module Admin
  module Marketing
    # Separates read and lifecycle permissions and limits serialized fields to
    # operator-safe configuration and audit metadata.
    class PlacementOfferPolicy < Core::ApplicationPolicy
      SAFE_FIELDS = %i[
        id code version surface daily_rate_minor currency minimum_duration_seconds maximum_duration_seconds
        terms_version status starts_at ends_at created_by_id activated_by_id retired_by_id activated_at retired_at
        created_at updated_at
      ].freeze

      def index? = allowed?(:index)
      def show? = allowed?(:show)
      def create? = allowed?(:create)
      def activate? = allowed?(:activate)
      def retire? = allowed?(:retire)

      VISIBILITY = %i[index show create activate retire].index_with do
        { admin: { fields: SAFE_FIELDS, include: [] }, default: { fields: [], include: [] } }
      end.freeze

      class Scope < Core::ApplicationPolicy::Scope
        def resolve
          return scope.none unless user
          return scope.all if user.super_admin? || user.has_permission?("marketing_placement_offer.index")

          scope.none
        end
      end

      private

      def allowed?(action)
        user&.super_admin? || user&.has_permission?("marketing_placement_offer.#{action}") == true
      end
    end
  end
end
