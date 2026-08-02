# frozen_string_literal: true

module Catalog
  module Products
    # Marks an event product retired (permanently hidden from sale). Retired
    # products cannot be reactivated.
    class Deactivate < Core::BaseService
      def initialize(product:, actor: nil)
        @product = product
        @actor = actor
      end

      def call
        ActiveRecord::Base.transaction do
          @product.lock!
          return success(@product) if @product.status == "retired"
          return failure(Core::Error.new("Only active products can be retired")) unless @product.status == "active"

          @product.status = "retired"
          @product.save!
          record_audit!
          publish_outbox!

          success(@product)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def record_audit!
        Core::Audit::Record.call(
          audit_key: "catalog-product-retired-#{@product.id}",
          action: "catalog.product.retired",
          auditable_type: "Catalog::EventProduct",
          auditable_id: @product.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: { status: [ "active", "retired" ] },
          metadata: { event_id: @product.event_id }
        )
      end

      def publish_outbox!
        Core::Outbox::Publish.call(
          topic: "catalog",
          event_type: "catalog.product.retired",
          aggregate: @product,
          payload: { product_id: @product.id, event_id: @product.event_id },
          idempotency_key: "catalog-product-retired-#{@product.id}"
        )
      end
    end
  end
end
