# frozen_string_literal: true

module Catalog
  module DateAllocations
    # Atomically replaces every date-allocation row for a draft product.
    #
    # Guards:
    # - only draft products may be replaced (active/retired are immutable);
    # - once any inventory or venue reservation exists, allocations freeze;
    # - every allocated date must already have at least one product access
    #   row — value is only distributed over dates the product actually grants;
    # - allocations must sum to exactly 10,000 basis points (100%).
    #
    # Runs inside one transaction with the product locked; a failed request
    # leaves the previous allocations intact.
    class Replace < Core::BaseService
      TOTAL_BASIS_POINTS = 10_000

      def initialize(product:, allocations:)
        @product = product
        @allocations = Array(allocations)
      end

      def call
        ActiveRecord::Base.transaction do
          @product.lock!
          validate_draft_only!
          validate_no_reservations!

          @allocations = default_allocations if @allocations.empty?

          # Preload all referenced dates once so row validation and insertion
          # never trigger a per-row `event_date` lookup (N+1).
          date_ids = @allocations.map { |a| a[:event_date_id] }
          dates_map = Events::EventDate.where(id: date_ids).index_by(&:id)

          validate_each_allocation!(dates_map)
          validate_access_on_each_date!
          validate_total! unless @allocations.empty?

          @product.product_date_allocations.delete_all
          @allocations.each do |attrs|
            @product.product_date_allocations.create!(allocation_attributes(attrs)) do |row|
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

        raise Core::Error, I18n.t("catalog.product_date_allocation.errors.replace_forbidden")
      end

      # Allocations freeze once any reservation touches the product — refunds
      # for schedule changes must always use the allocation that was live when
      # the purchase happened.
      def validate_no_reservations!
        has_inventory = @product.inventories.any? { |inv| inv.held_count.positive? || inv.sold_count.positive? }
        has_venue = Catalog::VenueCapacityReservation.where(event_product: @product).active.exists?
        return unless has_inventory || has_venue

        raise Core::Error, I18n.t("catalog.product_date_allocation.errors.immutable")
      end

      # When the request omits allocations, default to an even split across
      # every granted date so the organizer has a true no-effort path. Products
      # that never need allocation rows (single-date, `choose_one`, `full_only`)
      # resolve to an empty set.
      def default_allocations
        return [] unless eligible_for_equal_split?

        date_ids = granted_date_ids.sort
        base, remainder = TOTAL_BASIS_POINTS.divmod(date_ids.size)
        date_ids.each_with_index.map do |date_id, index|
          {
            event_date_id: date_id,
            allocation_basis_points: index < remainder ? base + 1 : base
          }
        end
      end

      def eligible_for_equal_split?
        return false if choose_one_product?
        return false if @product.schedule_change_refund_policy == "full_only"

        granted_date_ids.size >= 2
      end

      def choose_one_product?
        @product.ticket_type&.date_selection == "choose_one"
      end

      def granted_date_ids
        @product.product_accesses.distinct.pluck(:event_date_id)
      end

      def validate_each_allocation!(dates_map)
        # Reject duplicate date entries within the request before they hit the
        # unique index.
        seen = Set.new
        @allocations.each do |attrs|
          date_id = attrs[:event_date_id].to_s
          raise Core::Error, I18n.t(
            "catalog.product_date_allocation.errors.duplicate", date_id: date_id
          ) unless seen.add?(date_id)

          row = @product.product_date_allocations.new(allocation_attributes(attrs))
          row.event_date = dates_map[attrs[:event_date_id]] if dates_map.key?(attrs[:event_date_id])
          row.valid?
          # Ignore the "already taken" uniqueness error: the current rows are
          # deleted immediately after validation, so this only fires because
          # the old set is still present while we validate the new one.
          has_real_error = row.errors.any? { |e| e.attribute != :event_date_id || e.type != :taken }
          raise Core::Error, row.errors.full_messages.join(", ") if has_real_error
        end
      end

      # Value must only be distributed over dates the product actually grants
      # access to (spec §7.7).
      def validate_access_on_each_date!
        granted_date_ids = @product.product_accesses
          .where(event_date_id: @allocations.map { |a| a[:event_date_id] })
          .pluck(:event_date_id)
          .map(&:to_s)
        missing = @allocations.map { |a| a[:event_date_id].to_s }.uniq - granted_date_ids
        return if missing.empty?

        raise Core::Error, I18n.t("catalog.product_date_allocation.errors.missing_access", dates: missing.join(", "))
      end

      def validate_total!
        total = @allocations.sum { |attrs| attrs[:allocation_basis_points].to_i }
        return if total == TOTAL_BASIS_POINTS

        raise Core::Error, I18n.t("catalog.product_date_allocation.errors.sum_mismatch", total:)
      end

      def allocation_attributes(attrs)
        {
          event_date_id: attrs[:event_date_id],
          allocation_basis_points: attrs[:allocation_basis_points]
        }
      end
    end
  end
end
