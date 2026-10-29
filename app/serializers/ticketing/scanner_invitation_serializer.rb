# frozen_string_literal: true

module Ticketing
  # Exposes organizer-safe invitation state while excluding phone/token/code storage.
  class ScannerInvitationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :scanner_invitation

    attributes :id, :event_id, :organization_id, :masked_phone, :display_label,
               :organizer_note, :effective_status, :delivery_status, :delivery_revision,
               :zone_mode, :selected_zone_ids, :starts_at, :ends_at, :expires_at,
               :pairing_code_expires_at, :paired_at, :created_at, :updated_at
  end
end
