# frozen_string_literal: true

module Admin
  module Messaging
    # Admin CRUD for global baseline campaign template definitions. Content
    # versions remain separate immutable rows and are not rewritten here.
    class CampaignTemplatesController < Admin::ApplicationController
      include Core::CommandResponse
      include Core::Pagination
      include Core::Filterable

      before_action :set_clazz
      before_action :ensure_idempotency_key_present, only: %i[create update]
      before_action :set_template, only: %i[show update]

      def index
        authorize @clazz, :index?
        templates = policy_scope(@clazz).includes(eager_loaded_associations)
        templates = filter_records(templates)
        templates = apply_ordering(templates)
        total_count = templates.count if paginated_request?
        templates = paginated_request? ? apply_pagination(templates) : templates.limit(default_per_page)
        render_success(
          data: templates,
          serializer_options: { serializer: ::Admin::Messaging::CampaignTemplateSerializer },
          pagination: paginated_request? ? pagination_metadata(total_count) : nil
        )
      end

      def show
        authorize @template, :show?
        render_template
      end

      def create
        authorize @clazz.new, :create?
        result = ::Messaging::Campaigns::Templates::Upsert.call(
          template: @clazz.new, actor: current_user, attributes: template_params,
          idempotency_key:, action: "create"
        )
        render_service_result(
          result,
          success_status: :created,
          serializer_options: { serializer: ::Admin::Messaging::CampaignTemplateSerializer }
        )
      end

      def update
        authorize @template, :update?
        result = ::Messaging::Campaigns::Templates::Upsert.call(
          template: @template, actor: current_user, attributes: template_params,
          idempotency_key:, action: "update"
        )
        render_service_result(
          result,
          serializer_options: { serializer: ::Admin::Messaging::CampaignTemplateSerializer }
        )
      end

      private

      def set_clazz
        @clazz = ::Messaging::CampaignTemplate
      end

      def set_template
        @template = policy_scope(@clazz).find(params[:id])
      end

      def template_params
        params.require(:campaign_template).permit(:name, :channel, :status, metadata: {}).to_h
      end

      def render_template
        render_success(
          data: @template,
          serializer_options: { serializer: ::Admin::Messaging::CampaignTemplateSerializer }
        )
      end

      def eager_load_config
        { default: [ :versions ] }
      end

      def eager_loaded_associations
        eager_load_config.fetch(action_name.to_sym, eager_load_config.fetch(:default))
      end

      def allowed_order_columns
        %w[id organization_id name channel status created_at updated_at]
      end

      def serializer_profile
        fields = ::Admin::Messaging::CampaignTemplatePolicy::FIELDS
        { index: { fields:, include: [] }, show: { fields:, include: [] },
          create: { fields:, include: [] }, update: { fields:, include: [] } }
      end
    end
  end
end
