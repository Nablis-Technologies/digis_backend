# frozen_string_literal: true

require "digest"
require "json"

module Catalog
  module Inventory
    # Value object that captures the parameters for a single reserve call.
    # Produces a deterministic SHA-256 fingerprint over the canonical payload
    # (sorted keys, normalized dates) used for idempotency replay detection.
    # Dispatches owner_attributes to registration_id or order_item_id based
    # on the owner's class name.
    class ReservationRequest
      attr_reader :product, :event_date_ids, :venue_event_date_ids, :package_quantity,
                  :admissions_per_unit, :owner, :expires_at

      def initialize(product:, event_date_ids:, venue_event_date_ids: event_date_ids,
        package_quantity:, admissions_per_unit:, owner:, expires_at:)
        @product = product
        @event_date_ids = Array(event_date_ids).compact.map(&:to_s).uniq.sort
        @venue_event_date_ids = Array(venue_event_date_ids).compact.map(&:to_s).uniq.sort
        @package_quantity = package_quantity
        @admissions_per_unit = admissions_per_unit
        @owner = owner
        @expires_at = expires_at
      end

      def fingerprint
        @fingerprint ||= Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
      end

      def owner_attributes
        return {} if owner.nil?

        if owner_type.to_s.end_with?("OrderItem")
          { order_item_id: owner.id }
        else
          { registration_id: owner.id }
        end
      end

      private

      def canonical_payload
        {
          product_id: product.id.to_s,
          event_date_ids:,
          venue_event_date_ids:,
          package_quantity:,
          admissions_per_unit:,
          owner_type:,
          owner_id: owner&.id&.to_s,
          expires_at: expires_at&.utc&.iso8601(6)
        }
      end

      def owner_type
        owner&.class&.name
      end
    end
  end
end
