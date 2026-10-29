# frozen_string_literal: true

module Ticketing
  # Exposes scanner lifecycle state without ever serializing token material.
  class ScannerDeviceSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :scanner_device

    attributes :id, :organization_id, :device_identifier, :name, :status,
               :last_seen_at, :revoked_at, :created_at, :updated_at
  end
end
