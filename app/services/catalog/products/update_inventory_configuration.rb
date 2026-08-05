# frozen_string_literal: true

module Catalog
  module Products
    # Replaces the inventory mode and inventory records for a draft product.
    # Destroys all existing inventory rows and re-provisions according to the
    # new configuration. Rejected for active/retired products — inventory is
    # immutable once a product goes live.
    class UpdateInventoryConfiguration < Core::BaseService
      def initialize(product:, actor:, inventory_configuration:)
        @product = product
        @actor = actor
        @inventory_configuration = inventory_configuration.to_h.deep_symbolize_keys
      end

      def call
        ActiveRecord::Base.transaction do
          @product.lock!

            return failure_i18n("catalog.event_product.errors.active_immutable") if @product.status == "active"
            return failure_i18n("catalog.event_product.errors.retired_immutable") if @product.status == "retired"

          mode = @inventory_configuration[:mode]
          unless mode.is_a?(String) && mode.in?(Catalog::EventProduct::INVENTORY_MODES)
            raise Core::Error, I18n.t("catalog.event_product.errors.invalid_inventory_mode", mode: mode.inspect)
          end

          previous_mode = @product.inventory_mode
          @product.inventories.destroy_all
          @product.update!(inventory_mode: mode)

          provision_inventory!
          record_audit!(previous_mode)

          success(@product)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def provision_inventory!
        return if @product.inventory_mode == "unlimited"

        capacity = @inventory_configuration[:capacity]
        dates = @inventory_configuration[:dates] || []

        if @product.inventory_mode.in?(%w[event_wide event_wide_and_per_date])
          @product.inventories.create!(event_date_id: nil, capacity: capacity, held_count: 0, sold_count: 0)
        end

        if @product.inventory_mode.in?(%w[per_date event_wide_and_per_date])
          dates.each do |date_config|
            validate_date_belongs_to_event!(date_config[:event_date_id])
            @product.inventories.create!(
              event_date_id: date_config[:event_date_id],
              capacity: date_config[:capacity],
              held_count: 0,
              sold_count: 0
            )
          end
        end
      end

      def validate_date_belongs_to_event!(date_id)
        return if @product.event.event_dates.exists?(id: date_id)

          raise Core::Error, I18n.t("catalog.event_product.errors.event_date_event_mismatch", date_id: date_id)
      end

      def record_audit!(previous_mode)
        Core::Audit::Record.call(
          audit_key: "catalog-product-inventory-configured-#{@product.id}-#{@product.lock_version}",
          action: "catalog.product.inventory_configured",
          auditable_type: "Catalog::EventProduct",
          auditable_id: @product.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: { inventory_mode: [ previous_mode, @product.inventory_mode ] },
          metadata: {
            event_id: @product.event_id,
            inventory_count: @product.inventories.size
          }
        )
      end
    end
  end
end
