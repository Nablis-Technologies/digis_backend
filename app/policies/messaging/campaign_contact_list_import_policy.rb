# frozen_string_literal: true

module Messaging
  class CampaignContactListImportPolicy < Core::ApplicationPolicy
    FIELDS = %i[id campaign_contact_list_id created_by_id status filename total_rows accepted_rows duplicate_rows invalid_rows suppressed_rows missing_channel_rows error_detail started_at completed_at created_at updated_at].freeze

    def show? = organization_member?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } },
      import: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } }
    }.freeze

    private

    def organization_member?
      return true if user&.super_admin?

      record.campaign_contact_list && user&.member_of?(record.campaign_contact_list.organization)
    end
  end
end
