# frozen_string_literal: true

module Catalog
  module Products
    # Promotes a draft product to active status so it becomes purchasable.
    # Validates that inventory records and a usable price exist before
    # transitioning. Retired products cannot be reactivated.
    class Activate < Core::BaseService
      def initialize(product:, actor: nil)
        @product = product
        @actor = actor
      end

      def call
        ActiveRecord::Base.transaction do
          @product.lock!

          return success(@product) if @product.status == "active"
          return failure(Core::Error.new("Retired products cannot be reactivated")) if @product.status == "retired"

          validate_inventory_configuration!
          validate_price_exists!
          validate_zone_mappings!
          validate_allocations!

          @product.status = "active"
          @product.save!
          record_audit!

          success(@product)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def validate_inventory_configuration!
        has_event_wide = @product.inventories.exists?(event_date_id: nil)
        has_per_date = @product.inventories.where.not(event_date_id: nil).exists?

        valid_shape = case @product.inventory_mode
        when "unlimited" then !has_event_wide && !has_per_date
        when "event_wide" then has_event_wide && !has_per_date
        when "per_date" then !has_event_wide && has_per_date
        when "event_wide_and_per_date" then has_event_wide && has_per_date
        else false
        end
        raise Core::Error, "Inventory records do not match #{@product.inventory_mode} mode" unless valid_shape

        @product.inventories.each do |inv|
          if inv.capacity.to_i < 0
            raise Core::Error, "Inventory capacity must be non-negative"
          end
        end
      end

      def validate_price_exists!
        readiness_at = [ Time.current, @product.sales_start_at ].compact.max
        return if @product.prices.active_at(readiness_at).exists?

        raise Core::Error, "Product must have a usable price when sales open"
      end

      # When zones are enabled for an event date + access type, every
      # venue/parking access on that date must carry at least one explicit
      # zone grant. An empty mapping would silently mean "all zones" at the
      # gate (spec §7.6 / §2.32).
      def validate_zone_mappings!
        accesses = @product.product_accesses.includes(:product_access_zones, :event_date).to_a
        active_zones = active_zones_for(accesses)

        accesses.each do |access|
          next unless access.venue? || access.parking?
          next unless zones_active_for?(access, active_zones)

          if access.product_access_zones.empty?
            raise Core::Error,
                  I18n.t("catalog.event_product.errors.zone_mapping_required",
                         type: access.type, date: access.event_date_id)
          end
        end
      end

      def active_zones_for(accesses)
        types = accesses.filter_map { |access| access.type if access.venue? || access.parking? }.uniq
        return [] if types.empty?

        Events::AccessZone.active
          .where(event_id: @product.event_id, type: types)
          .pluck(:type, :event_date_id)
      end

      # Multi-date `fixed` products with `full_or_partial` refunds must have a
      # date allocation for every granted date before sales begin. Single-date
      # and `choose_one` products implicitly allocate 100% to the buyer's date
      # and need no rows (spec §7.7).
      def validate_allocations!
        return if @product.ticket_type&.date_selection == "choose_one"
        return if @product.schedule_change_refund_policy == "full_only"

        granted_ids = @product.product_accesses.distinct.pluck(:event_date_id)
        return if granted_ids.size < 2

        allocated_ids = @product.product_date_allocations.pluck(:event_date_id)
        missing = granted_ids - allocated_ids
        return if missing.empty?

        raise Core::Error,
              I18n.t("catalog.event_product.errors.allocations_required",
                     dates: missing.sort.join(", "))
      end

      def zones_active_for?(access, active_zones)
        return active_zones.any? { |type, _date_id| type == access.type } if access.event_date_id.blank?

        active_zones.include?([ access.type, nil ]) ||
          active_zones.include?([ access.type, access.event_date_id ])
      end

      def record_audit!
        Core::Audit::Record.call(
          audit_key: "catalog-product-activated-#{@product.id}",
          action: "catalog.product.activated",
          auditable_type: "Catalog::EventProduct",
          auditable_id: @product.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: { status: [ "draft", "active" ] },
          metadata: { event_id: @product.event_id }
        )
      end
    end
  end
end
