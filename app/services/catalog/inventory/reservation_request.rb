# frozen_string_literal: true

require "digest"
require "json"

module Catalog
  module Inventory
    # Adds reservation lifecycle metadata and idempotency identity to a shared
    # capacity line. Read-only checks use Line directly.
    class ReservationRequest
      attr_reader :line, :owner, :expires_at

      def initialize(line:, owner:, expires_at:)
        raise ArgumentError, "line must be a Catalog::Inventory::Line" unless line.is_a?(Line)

        @line = line
        @owner = owner
        @expires_at = expires_at
      end

      def fingerprint
        @fingerprint ||= Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
      end

      def owner_attributes
        return {} if owner.nil?

        if owner.class.name.to_s.end_with?("OrderItem")
          { order_item_id: owner.id }
        else
          { registration_id: owner.id }
        end
      end

      private

      def canonical_payload
        {
          product_id: line.product.id.to_s,
          event_date_ids: line.event_date_ids,
          venue_event_date_ids: line.venue_event_date_ids,
          package_quantity: line.package_quantity,
          admissions_per_unit: line.admissions_per_unit,
          owner_type: owner&.class&.name,
          owner_id: owner&.id&.to_s,
          expires_at: expires_at&.utc&.iso8601(6)
        }
      end
    end
  end
end
