# frozen_string_literal: true

module Admin
  module Messaging
    # Read-only operational campaign view for platform administrators.
    class CampaignsController < Admin::ApplicationController
      include Core::Pagination
      include Core::Filterable

      before_action :set_clazz
      before_action :set_campaign, only: :show

      def index
        authorize @clazz, :index?
        campaigns = policy_scope(@clazz).includes(eager_loaded_associations)
        campaigns = filter_records(campaigns)
        campaigns = apply_ordering(campaigns)
        total_count = campaigns.count if paginated_request?
        campaigns = paginated_request? ? apply_pagination(campaigns) : campaigns.limit(default_per_page)
        render_success(
          data: campaigns,
          serializer_options: { serializer: ::Admin::Messaging::CampaignSerializer },
          pagination: paginated_request? ? pagination_metadata(total_count) : nil
        )
      end

      def show
        authorize @campaign, :show?
        render_success(
          data: @campaign,
          serializer_options: { serializer: ::Admin::Messaging::CampaignSerializer }
        )
      end

      private

      def set_clazz
        @clazz = ::Messaging::Campaign
      end

      def set_campaign
        @campaign = policy_scope(@clazz).includes(eager_loaded_associations).find(params[:id])
      end

      def eager_load_config
        { default: [ :audience_snapshot ] }
      end

      def eager_loaded_associations
        eager_load_config.fetch(action_name.to_sym, eager_load_config.fetch(:default))
      end

      def allowed_order_columns
        %w[id organization_id name channel status timezone send_at launched_at completed_at created_at updated_at]
      end

      def serializer_profile
        fields = ::Admin::Messaging::CampaignPolicy::FIELDS
        { index: { fields:, include: [] }, show: { fields:, include: [] } }
      end
    end
  end
end
