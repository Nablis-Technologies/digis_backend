# frozen_string_literal: true

module Admin
  module Messaging
    # Lists quota policies and applies idempotent, audited policy updates.
    class CampaignVolumePoliciesController < Admin::ApplicationController
      include Core::CommandResponse
      include Core::Pagination
      include Core::Filterable

      before_action :set_clazz
      before_action :ensure_idempotency_key_present, only: :update
      before_action :set_policy, only: %i[show update]

      def index
        authorize @clazz, :index?
        policies = policy_scope(@clazz).includes(eager_loaded_associations)
        policies = filter_records(policies)
        policies = apply_ordering(policies)
        total_count = policies.count if paginated_request?
        policies = paginated_request? ? apply_pagination(policies) : policies.limit(default_per_page)
        render_success(
          data: policies,
          serializer_options: { serializer: ::Admin::Messaging::CampaignVolumePolicySerializer },
          pagination: paginated_request? ? pagination_metadata(total_count) : nil
        )
      end

      def show
        authorize @policy, :show?
        render_policy
      end

      def update
        authorize @policy, :update?
        result = ::Messaging::Campaigns::VolumePolicies::Update.call(
          policy: @policy, actor: current_user, attributes: policy_params, idempotency_key:
        )
        render_service_result(
          result,
          serializer_options: { serializer: ::Admin::Messaging::CampaignVolumePolicySerializer }
        )
      end

      private

      def set_clazz
        @clazz = ::Messaging::CampaignVolumePolicy
      end

      def set_policy
        @policy = policy_scope(@clazz).find(params[:id])
      end

      def policy_params
        params.require(:campaign_volume_policy).permit(:timezone, :daily_limit, :monthly_limit, :active).to_h
      end

      def render_policy
        render_success(
          data: @policy,
          serializer_options: { serializer: ::Admin::Messaging::CampaignVolumePolicySerializer }
        )
      end

      def eager_load_config
        { default: %i[organization updated_by] }
      end

      def eager_loaded_associations
        eager_load_config.fetch(action_name.to_sym, eager_load_config.fetch(:default))
      end

      def allowed_order_columns
        %w[id organization_id channel timezone daily_limit monthly_limit active created_at updated_at]
      end

      def serializer_profile
        fields = ::Admin::Messaging::CampaignVolumePolicyPolicy::FIELDS
        { index: { fields:, include: [] }, show: { fields:, include: [] }, update: { fields:, include: [] } }
      end
    end
  end
end
