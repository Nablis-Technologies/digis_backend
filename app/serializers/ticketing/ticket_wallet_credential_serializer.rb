# frozen_string_literal: true

module Ticketing
  # Owner-facing credential projection. Bearer QR/PNR values are returned only
  # for the current active ticket through the authenticated wallet boundary.
  class TicketWalletCredentialSerializer < ActiveModel::Serializer
    attributes :id, :credential_generation_id, :admission_slot_id, :slot_positions,
               :entry_limit, :status, :issued_at, :lookup_code, :qr_token

    def lookup_code
      return unless instance_options[:deliver_secret]

      object.lookup_code
    end

    def qr_token
      return unless instance_options[:deliver_secret]

      object.qr_token
    end
  end
end
