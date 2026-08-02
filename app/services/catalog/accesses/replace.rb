# frozen_string_literal: true

module Catalog
  module Accesses
    # Atomically replaces every product access row for a draft product.
    #
    # Guards:
    # - only draft products may be replaced (active/retired are immutable);
    # - once any inventory or venue reservation exists, access rows freeze;
    # - each incoming row must be internally valid, must reference an event
    #   date belonging to the product's event, and no (date, type) pair may
    #   repeat within one request.
    #
    # Runs inside one transaction: the product row is locked, the new rows are
    # validated before any delete happens, then the old set is removed and the
    # new set inserted, so a failed request leaves the previous accesses intact.
    class Replace < Core::BaseService
      attr_reader :product

      def initialize(product:, accesses:)
        @product = product
        @accesses = Array(accesses)
      end

      def call
        ActiveRecord::Base.transaction do
          @product.lock!
          validate_draft_only!
          validate_no_reservations!

          # Preload all referenced dates once so row validation and insertion
          # never trigger a per-row `event_date` lookup (N+1).
          date_ids = @accesses.map { |a| a[:event_date_id] }
          dates_map = Events::EventDate.where(id: date_ids).index_by(&:id)

          validate_each_draft!(@accesses, dates_map)

          @product.product_accesses.delete_all
          @accesses.each do |attrs|
            @product.product_accesses.create!(access_attributes(attrs)) do |row|
              row.event_date = dates_map[attrs[:event_date_id]] if dates_map.key?(attrs[:event_date_id])
            end
          end

          success(@product.reload)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def validate_draft_only!
        return if @product.status == "draft"

        raise Core::Error, I18n.t("catalog.product_access.errors.replace_forbidden")
      end

      # Access rows freeze once any reservation touches the product — a
      # credential granted by the current set must never silently change
      # underneath issued tickets.
      def validate_no_reservations!
        has_inventory = @product.inventories.any? { |inv| inv.held_count.positive? || inv.sold_count.positive? }
        has_venue = Catalog::VenueCapacityReservation.where(event_product: @product).active.exists?
        return unless has_inventory || has_venue

        raise Core::Error, I18n.t("catalog.product_access.errors.immutable")
      end

      def validate_each_draft!(accesses, dates_map)
        # Reject duplicate (date, type) pairs within the request before they
        # hit the unique index.
        seen = Set.new
        accesses.each do |attrs|
          date_id = attrs[:event_date_id].to_s
          type_val = attrs[:type].to_s

          raise Core::Error, I18n.t(
            "catalog.product_access.errors.duplicate",
            date_id: date_id,
            type: type_val
          ) unless seen.add?([ date_id, type_val ])

          row = @product.product_accesses.new(access_attributes(attrs))
          row.event_date = dates_map[attrs[:event_date_id]] if dates_map.key?(attrs[:event_date_id])
          row.valid?
          # Ignore the "already taken" uniqueness error: the current rows are
          # deleted immediately after validation, so this only fires because
          # the old set is still present while we validate the new one.
          has_real_error = row.errors.any? { |e| e.attribute != :event_date_id || e.type != :taken }
          raise Core::Error, row.errors.full_messages.join(", ") if has_real_error
        end
      end

      def access_attributes(attrs)
        {
          event_date_id: attrs[:event_date_id],
          type: attrs[:type],
          usage_limit: attrs.key?(:usage_limit) ? attrs[:usage_limit] : 1,
          opens_offset_seconds: attrs[:opens_offset_seconds],
          closes_offset_seconds: attrs[:closes_offset_seconds],
          required_access_protection: attrs[:required_access_protection]
        }
      end
    end
  end
end
