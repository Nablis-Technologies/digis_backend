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
