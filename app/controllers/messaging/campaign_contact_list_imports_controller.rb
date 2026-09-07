# frozen_string_literal: true

module Messaging
  class CampaignContactListImportsController < Messaging::ApplicationController
    before_action :set_import

    def show
      authorize @import, :show?
      render_success(data: @import, serializer_options: { serializer: CampaignContactListImportSerializer })
    end

    def report
      authorize @import, :show?
      return head :not_found unless @import.rejected_report.attached?

      send_data @import.rejected_report.download, filename: @import.rejected_report.filename.to_s,
        type: "text/csv", disposition: "attachment"
    end

    private

    def set_import
      @import = CampaignContactListImport.joins(:campaign_contact_list)
        .where(messaging_campaign_contact_lists: { organization_id: params[:organization_id], id: params[:id] })
        .find(params[:import_id])
    end

    def serializer_profile
      { show: { fields: CampaignContactListImportPolicy::FIELDS, include: [] } }
    end
  end
end
