# frozen_string_literal: true

module Admin
  module Marketing
    # Administrative CRUD is intentionally read/create-only; immutable policy
    # versions change state exclusively through audited activate/retire commands.
    class PlacementCapacityPoliciesController < Admin::ApplicationController
      include Core::Pagination
      include Core::Filterable
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: %i[create activate retire]
      before_action :set_policy, only: %i[show activate retire]

      def index
        policy_class = ::Marketing::PlacementCapacityPolicy
        authorize policy_class, :index?
        policies = apply_ordering(filter_records(policy_scope(policy_class).order(created_at: :desc, id: :desc)))
        total_count = policies.count if paginated_request?
        policies = paginated_request? ? apply_pagination(policies) : policies.limit(default_per_page)
        render_success(
          data: policies,
          serializer_options: { serializer: ::Admin::Marketing::PlacementCapacityPolicySerializer },
          pagination: paginated_request? ? pagination_metadata(total_count) : nil
        )
      end

      def show
        authorize @capacity_policy, :show?
        render_success(
          data: @capacity_policy,
          serializer_options: { serializer: ::Admin::Marketing::PlacementCapacityPolicySerializer }
        )
      end

      def create
        authorize ::Marketing::PlacementCapacityPolicy.new, :create?
        result = ::Marketing::PlacementCapacityPolicies::Create.call(
          actor: current_user, attributes: capacity_policy_params, idempotency_key:, reason: params[:reason]
        )
        render_service_result(
          result, success_status: :created,
          serializer_options: { serializer: ::Admin::Marketing::PlacementCapacityPolicySerializer }
        )
      end

      def activate
        authorize @capacity_policy, :activate?
        result = ::Marketing::PlacementCapacityPolicies::Activate.call(
          policy_id: @capacity_policy.id, actor: current_user, idempotency_key:, reason: params[:reason]
        )
        render_service_result(result,
          serializer_options: { serializer: ::Admin::Marketing::PlacementCapacityPolicySerializer })
      end

      def retire
        authorize @capacity_policy, :retire?
        result = ::Marketing::PlacementCapacityPolicies::Retire.call(
          policy_id: @capacity_policy.id, actor: current_user, idempotency_key:, reason: params[:reason]
        )
        render_service_result(result,
          serializer_options: { serializer: ::Admin::Marketing::PlacementCapacityPolicySerializer })
      end

      private

      def set_policy
        @capacity_policy = ::Marketing::PlacementCapacityPolicy.find(params[:id])
      end

      def capacity_policy_params
        params.require(:placement_capacity_policy).permit(
          :surface, :max_concurrent, :effective_from, :effective_until
        ).to_h
      end

      def allowed_order_columns
        %w[id surface version max_concurrent status effective_from effective_until created_at updated_at]
      end
    end
  end
end
