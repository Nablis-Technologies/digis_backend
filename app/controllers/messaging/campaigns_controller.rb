# frozen_string_literal: true

module Messaging
  # Organizer campaign API; lifecycle transitions delegate to campaign commands.
  class CampaignsController < Messaging::ApplicationController
    include Core::CommandResponse

    before_action :set_organization
    before_action :set_campaign, only: %i[show update estimate attest launch pause resume cancel abort analytics]
    before_action :ensure_idempotency_key_present, only: %i[create update estimate attest launch pause resume cancel abort]

    def index
      @clazz = Campaign
      authorize Campaign.new(organization: @organization), :index?
      campaigns = policy_scope(Campaign.where(organization: @organization)).includes(eager_loaded_associations)
      campaigns = filter_records(campaigns)
      campaigns = apply_ordering(campaigns)
      total_count = campaigns.count if paginated_request?
      campaigns = paginated_request? ? apply_pagination(campaigns) : campaigns.limit(default_per_page)
      render_success(data: campaigns, serializer_options: { serializer: CampaignSerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil)
    end

    def show
      authorize @campaign
      render_success(data: @campaign, serializer_options: { serializer: CampaignSerializer })
    end

    def create
      authorize Campaign.new(organization: @organization), :create?
      result = Campaigns::Create.call(
        organization: @organization, actor: current_user, idempotency_key:,
        **campaign_params.symbolize_keys.slice(
          :name, :channel, :timezone, :event_id, :message_subject, :message_body, :variables, :metadata
        )
      )
      render_service_result(result, success_status: :created, serializer_options: { serializer: CampaignSerializer })
    end

    def update
      authorize @campaign
      result = Campaigns::Update.call(campaign: @campaign, actor: current_user,
        attributes: campaign_params, idempotency_key:)
      render_service_result(result, serializer_options: { serializer: CampaignSerializer })
    end

    def estimate
      authorize @campaign
      result = Campaigns::Estimate.call(campaign: @campaign, actor: current_user, idempotency_key:)
      render_service_result(result, success_status: result.value.is_a?(Hash) && result.value[:status] == "preparing" ? :accepted : :ok)
    end

    def attest
      authorize @campaign
      result = Campaigns::Attest.call(
        campaign: @campaign, audience_snapshot: @campaign.audience_snapshot, actor: current_user,
        channel: @campaign.channel, confirmation: params[:confirmation], historical_basis: params[:historical_basis],
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      attestation = result.value
      render_success(data: {
        id: attestation.id, campaign_id: attestation.campaign_id,
        audience_snapshot_id: attestation.audience_snapshot_id, channel: attestation.channel,
        historical_basis: attestation.historical_basis, statement_version: attestation.statement_version,
        attested_at: attestation.attested_at
      })
    end

    def launch
      authorize @campaign
      result = Campaigns::Launch.call(campaign: @campaign, actor: current_user, idempotency_key:,
        quote_digest: params[:quote_digest].presence || params.dig(:campaign, :quote_digest),
        quoted_rate_version_id: params[:quoted_rate_version_id].presence || params.dig(:campaign, :quoted_rate_version_id),
        quoted_quantity: params[:quoted_quantity].presence || params.dig(:campaign, :quoted_quantity))
      render_service_result(result, serializer_options: { serializer: CampaignSerializer })
    end

    def pause
      authorize @campaign
      render_service_result(Campaigns::Pause.call(campaign: @campaign, actor: current_user, idempotency_key:),
        serializer_options: { serializer: CampaignSerializer })
    end

    def resume
      authorize @campaign
      render_service_result(Campaigns::Resume.call(campaign: @campaign, actor: current_user, idempotency_key:),
        serializer_options: { serializer: CampaignSerializer })
    end

    def cancel
      authorize @campaign
      result = Campaigns::Cancel.call(campaign: @campaign, actor: current_user,
        reason: lifecycle_reason, idempotency_key:)
      render_service_result(result, serializer_options: { serializer: CampaignSerializer })
    end

    def abort
      authorize @campaign
      result = Campaigns::Abort.call(campaign: @campaign, actor: current_user,
        reason: lifecycle_reason, idempotency_key:)
      render_service_result(result, serializer_options: { serializer: CampaignSerializer })
    end

    def analytics
      authorize @campaign
      result = Campaigns::Analytics.call(campaign: @campaign)
      render_service_result(result)
    end

    private

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def set_campaign
      @campaign = policy_scope(Campaign.where(organization: @organization)).includes(:audience_snapshot).find(params[:id])
    end

    def campaign_params
      params.fetch(:campaign, {}).permit(
        :name, :channel, :timezone, :event_id, :message_subject, :message_body, metadata: {}, variables: {}
      ).to_h
    end

    def lifecycle_reason
      params[:reason].presence || params.dig(:campaign, :reason)
    end

    def eager_load_config
      { index: [ :audience_snapshot ], show: [ :audience_snapshot ], default: [] }
    end

    def eager_loaded_associations
      eager_load_config.fetch(action_name.to_sym, eager_load_config.fetch(:default))
    end

    def allowed_order_columns
      %w[id name channel status timezone send_at launched_at completed_at created_at]
    end

    def serializer_profile
      fields = CampaignPolicy::FIELDS
      { index: { fields:, include: [] }, show: { fields:, include: [] }, create: { fields:, include: [] },
        update: { fields:, include: [] }, launch: { fields:, include: [] }, pause: { fields:, include: [] },
        cancel: { fields:, include: [] }, abort: { fields:, include: [] }, attest: { fields:, include: [] },
        resume: { fields:, include: [] }, analytics: { fields:, include: [] } }
    end
  end
end
