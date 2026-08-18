# frozen_string_literal: true

module Ticketing
  # Generation transition response with safe credential metadata. It never
  # serializes QR, PNR, claim token, or encrypted holder data.
  class CredentialGenerationSerializer < ActiveModel::Serializer
    attributes :id, :ticket_id, :version, :mode, :status, :activated_at,
               :revoked_at, :revocation_reason, :created_at, :updated_at

    has_many :credentials, serializer: Ticketing::CredentialSerializer
  end
end
