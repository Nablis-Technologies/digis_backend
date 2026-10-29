# frozen_string_literal: true

module Admin
  module Marketing
    # Provides independent permissions for capacity supply, separate from
    # permission to manage offer rates and terms.
    class PlacementCapacityPolicyPolicy < Core::ApplicationPolicy
      SAFE_FIELDS = %i[
        id surface version max_concurrent status effective_from effective_until created_by_id activated_by_id
        retired_by_id activated_at retired_at created_at updated_at
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
          return scope.all if user.super_admin? || user.has_permission?("marketing_placement_capacity_policy.index")

          scope.none
        end
      end

      private

      def allowed?(action)
        user&.super_admin? || user&.has_permission?("marketing_placement_capacity_policy.#{action}") == true
      end
    end
  end
end
