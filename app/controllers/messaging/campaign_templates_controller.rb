# frozen_string_literal: true

module Messaging
  class CampaignTemplatesController < Messaging::ApplicationController
    include Core::CommandResponse

    before_action :set_organization
    before_action :set_template, only: %i[show update]
    before_action :ensure_idempotency_key_present, only: %i[create update]

    def index
      @clazz = CampaignTemplate
      authorize CampaignTemplate.new(organization: @organization), :index?
      templates = policy_scope(CampaignTemplate.where(organization: [ @organization, nil ])).order(:name)
      templates = filter_records(templates)
      templates = apply_ordering(templates)
      total_count = templates.count if paginated_request?
      templates = paginated_request? ? apply_pagination(templates) : templates.limit(default_per_page)
      render_success(data: templates, serializer_options: { serializer: CampaignTemplateSerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil)
    end

    def show
      authorize @template
      render_success(data: @template, serializer_options: { serializer: CampaignTemplateSerializer })
    end

    def create
      authorize CampaignTemplate.new(organization: @organization), :create?
      result = Campaigns::Templates::Upsert.call(
        template: CampaignTemplate.new, organization: @organization, actor: current_user,
        attributes: template_params, idempotency_key:, action: "create"
      )
      render_service_result(result, success_status: :created,
        serializer_options: { serializer: CampaignTemplateSerializer })
    end

    def update
      authorize @template
      result = Campaigns::Templates::Upsert.call(
        template: @template, organization: @organization, actor: current_user,
        attributes: template_params, idempotency_key:, action: "update"
      )
      render_service_result(result, serializer_options: { serializer: CampaignTemplateSerializer })
    end

    private

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def set_template
      @template = policy_scope(CampaignTemplate.where(organization: [ @organization, nil ])).find(params[:id])
    end

    def template_params
      params.fetch(:campaign_template, {}).permit(:name, :channel, :status, metadata: {}).to_h
    end

    def allowed_order_columns
      %w[id name channel status created_at updated_at]
    end

    def serializer_profile
      { index: { fields: CampaignTemplatePolicy::FIELDS, include: [] },
        show: { fields: CampaignTemplatePolicy::FIELDS, include: [] },
        create: { fields: CampaignTemplatePolicy::FIELDS, include: [] },
        update: { fields: CampaignTemplatePolicy::FIELDS, include: [] } }
    end
  end
end
