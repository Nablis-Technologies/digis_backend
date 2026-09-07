# frozen_string_literal: true

module Messaging
  class CampaignContactListEntriesController < Messaging::ApplicationController
    include Core::CommandResponse

    before_action :set_list
    before_action :set_entry, only: :destroy
    before_action :ensure_idempotency_key_present

    def create
      authorize @list, :append?
      result = Campaigns::ContactLists::AddEntry.call(
        list: @list, row: entry_params, actor: current_user, idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: CampaignContactListSerializer })
    end

    def destroy
      authorize @entry, :destroy?
      result = Campaigns::ContactLists::RemoveEntry.call(entry: @entry, actor: current_user, idempotency_key:)
      render_service_result(result, serializer_options: { serializer: CampaignContactListEntrySerializer })
    end

    private

    def set_list
      @list = policy_scope(CampaignContactList.where(organization_id: params[:organization_id])).find(params[:campaign_contact_list_id])
    end

    def set_entry
      @entry = @list.entries.find(params[:id])
    end

    def entry_params
      params.fetch(:entry, params.fetch(:campaign_contact_list_entry, {})).permit(
        :phone_number, :email, :first_name, :last_name
      ).to_h
    end

    def eager_load_config
      { default: [] }
    end

    def serializer_profile
      { create: { fields: CampaignContactListPolicy::FIELDS, include: [] },
        destroy: { fields: CampaignContactListEntryPolicy::FIELDS, include: [] } }
    end
  end
end
