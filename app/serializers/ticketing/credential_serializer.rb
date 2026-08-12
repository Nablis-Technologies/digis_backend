# frozen_string_literal: true

module Ticketing
  # Credential projection for package workflows. Bearer QR tokens and lookup
  # codes are deliberately excluded; delivery of those secrets belongs to the
  # authenticated credential-wallet boundary, not generic resource responses.
  class CredentialSerializer < ActiveModel::Serializer
    attributes :id, :ticket_id, :credential_generation_id, :admission_slot_id,
               :event_id, :type, :holder_user_id, :status, :slot_positions,
               :entry_limit, :issued_at, :revoked_at, :revocation_reason,
               :created_at, :updated_at
  end
end
