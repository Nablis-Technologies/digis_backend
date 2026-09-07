# frozen_string_literal: true

module Messaging
  # Exposes contact-presence flags only; raw addresses and keyed digests stay private.
  class CampaignContactListEntrySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :status, :source, :phone_present, :email_present, :created_at, :updated_at

    def phone_present = object.phone_digest.present?
    def email_present = object.email_digest.present?
  end
end
