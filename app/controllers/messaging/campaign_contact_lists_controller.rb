# frozen_string_literal: true

module Messaging
  class CampaignContactListsController < Messaging::ApplicationController
    include Core::CommandResponse

    before_action :set_organization
    before_action :set_list, only: %i[show update destroy import append replace]
    before_action :ensure_idempotency_key_present, only: %i[create update destroy import append replace]

    def index
      @clazz = CampaignContactList
      authorize CampaignContactList.new(organization: @organization), :index?
      lists = policy_scope(CampaignContactList.where(organization: @organization)).order(:name)
      lists = filter_records(lists)
      lists = apply_ordering(lists)
      total_count = lists.count if paginated_request?
      lists = paginated_request? ? apply_pagination(lists) : lists.limit(default_per_page)
      render_success(data: lists, serializer_options: { serializer: CampaignContactListSerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil)
    end

    def show
      authorize @list
      render_success(data: @list, serializer_options: { serializer: CampaignContactListSerializer })
    end

    def create
      authorize CampaignContactList.new(organization: @organization), :create?
      result = Campaigns::ContactLists::Create.call(
        organization: @organization, actor: current_user, name: list_params[:name], idempotency_key:
      )
      render_service_result(result, success_status: :created,
        serializer_options: { serializer: CampaignContactListSerializer })
    end

    def update
      authorize @list
      result = Campaigns::ContactLists::Update.call(
        list: @list, actor: current_user, attributes: list_params, idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: CampaignContactListSerializer })
    end

    def destroy
      authorize @list
      result = Campaigns::ContactLists::Update.call(
        list: @list, actor: current_user, attributes: { status: "archived" }, idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: CampaignContactListSerializer })
    end

    def import
      authorize @list
      file = params.require(:file)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: file.tempfile, filename: file.original_filename, content_type: file.content_type
      )
      result = Campaigns::ContactLists::Import.call(
        list: @list, blob:, actor: current_user, idempotency_key:
      )
      render_service_result(result, success_status: :accepted,
        serializer_options: { serializer: CampaignContactListImportSerializer })
    end

    def append
      authorize @list
      result = Campaigns::ContactLists::Append.call(
        list: @list, rows: rows_param, actor: current_user, idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: CampaignContactListSerializer })
    end

    def replace
      authorize @list
      result = Campaigns::ContactLists::Replace.call(
        list: @list, rows: rows_param, confirm: params[:confirm] == true || params[:confirm].to_s == "true",
        actor: current_user, idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: CampaignContactListSerializer })
    end

    private

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def set_list
      @list = policy_scope(CampaignContactList.where(organization: @organization)).find(params[:id])
    end

    def list_params
      params.fetch(:campaign_contact_list, {}).permit(:name, :status).to_h
    end

    def rows_param
      raw_rows = params[:rows] || params.dig(:campaign_contact_list, :rows) || []
      Array(raw_rows).map do |row|
        attributes = row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row
        ActionController::Parameters.new(attributes).permit(
          :phone_number, :email, :first_name, :last_name
        ).to_h
      end
    end

    def allowed_order_columns
      %w[id name status version created_at updated_at]
    end

    def serializer_profile
      { index: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        show: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        create: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        update: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        destroy: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        import: { fields: CampaignContactListImportPolicy::FIELDS, include: [] },
        append: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        replace: { fields: CampaignContactListPolicy::FIELDS, include: [] } }
    end
  end
end
