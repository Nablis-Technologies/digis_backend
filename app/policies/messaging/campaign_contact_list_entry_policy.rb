# frozen_string_literal: true

module Messaging
  class CampaignContactListEntryPolicy < Core::ApplicationPolicy
    FIELDS = %i[id status source phone_present email_present created_at updated_at].freeze

    def destroy? = organization_admin?

    VISIBILITY = {
      destroy: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } }
    }.freeze

    private

    def organization_admin?
      return true if user&.super_admin?

      record.campaign_contact_list &&
        Events::AuthorizationResolver.organization_admin?(user, record.campaign_contact_list.organization)
    end
  end
end
