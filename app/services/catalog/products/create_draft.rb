# frozen_string_literal: true

require "digest"

module Catalog
  module Products
    # Creates an event product in draft status, optionally provisioning inventory
    # records, a ticket type, and an initial price. This is the primary entry
    # point for product creation — callers must provide an explicit
    # inventory_configuration hash. Use Activate to promote to live status.
    #
    # inventory_configuration must at minimum include `mode`. For `unlimited`
    # mode no further fields are needed. For other modes, `capacity` and
    # optionally `dates` are required.
    #
    # price_attributes, when provided, creates an initial price atomically (e.g.
    # `{ type: "override", currency: "USD", amount_minor: 2500 }`).
    class CreateDraft < Core::BaseService
      def initialize(event:, actor:, product_attributes:, ticket_type_attributes: nil, price_attributes: nil, inventory_configuration:, idempotency_key: nil)
        @event = event
        @actor = actor
        @product_attributes = normalize_hash(product_attributes)
        @ticket_type_attributes = normalize_optional_hash(ticket_type_attributes)
        @price_attributes = normalize_optional_hash(price_attributes)
        @inventory_configuration = normalize_hash(inventory_configuration)
        @raw_idempotency_key = idempotency_key
      end

      def call
        prepare_idempotency!
        ActiveRecord::Base.transaction do
          validate_inventory_configuration_present!
          lock_idempotency_scope!

          product_from_replay = find_existing_for_idempotency_key!
          return success(product_from_replay) if product_from_replay

          @product = Catalog::EventProduct.new(@product_attributes.merge(event: @event, status: "draft"))

          resolve_inventory_mode!

          if @product.ticket?
            return failure_i18n("catalog.event_product.errors.ticket_type_attributes_required") if @ticket_type_attributes.blank?

            @product.build_ticket_type(@ticket_type_attributes)
          end

          unless @product.valid? && ticket_type_valid?
            return failure(Core::Error.new(@product.errors.full_messages.join(", ")))
          end

          if @idempotency_key
            @product.idempotency_key_digest = @idempotency_key.digest
            @product.creation_request_digest = @request_digest
          end
          @product.save!
          @product.ticket_type&.save! if @product.ticket_type&.new_record?

          provision_inventory!
          provision_price!
          record_audit!

          success(@product)
        end
      rescue ArgumentError => e
        failure(Core::Error.new(e.message))
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def prepare_idempotency!
        return if @raw_idempotency_key.blank?

        @idempotency_key = Core::IdempotencyKey.new(@raw_idempotency_key)
        @request_digest = request_digest
      end

      def find_existing_for_idempotency_key!
        return nil unless @idempotency_key

        product = Catalog::EventProduct.find_by(
          event_id: @event.id,
          idempotency_key_digest: @idempotency_key.digest
        )
        return nil unless product
        return product if product.creation_request_digest == @request_digest

        raise Core::Error, I18n.t("catalog.event_product.errors.idempotency_conflict")
      end

      def lock_idempotency_scope!
        return unless @idempotency_key

        Core::Database::AdvisoryLock.acquire!(
          "catalog-product-create",
          @event.id,
          @idempotency_key.digest
        )
      end

      def validate_inventory_configuration_present!
        return if @inventory_configuration.is_a?(Hash)

        raise Core::Error, I18n.t("catalog.event_product.errors.inventory_configuration_required")
      end

      def resolve_inventory_mode!
        mode = @inventory_configuration[:mode]
        unless mode.is_a?(String) && mode.in?(Catalog::EventProduct::INVENTORY_MODES)
          raise Core::Error, I18n.t("catalog.event_product.errors.invalid_inventory_mode", mode: mode.inspect)
        end

        @product.inventory_mode = mode
      end

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
        return if @event.event_dates.exists?(id: date_id)

        raise Core::Error, I18n.t("catalog.event_product.errors.event_date_event_mismatch", date_id: date_id)
      end

      def provision_price!
        return if @price_attributes.blank?

        @product.prices.create!(@price_attributes.merge(type: @price_attributes[:type] || "override"))
      end

      def ticket_type_valid?
        return true if @product.ticket_type.blank?
        return true if @product.ticket_type.valid?

        @product.ticket_type.errors.each { |error| @product.errors.import(error) }
        false
      end

      def request_digest
        payload = {
          product: @product_attributes,
          ticket_type: @ticket_type_attributes,
          price: @price_attributes,
          inventory: @inventory_configuration
        }
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(canonical(payload)))
      end

      def canonical(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical(nested) }
        when Array
          value.map { |nested| canonical(nested) }
        else
          value.as_json
        end
      end

      def normalize_hash(value)
        value.to_h.deep_symbolize_keys
      end

      def normalize_optional_hash(value)
        return if value.blank?

        normalize_hash(value)
      end

      def record_audit!
        Core::Audit::Record.call(
          audit_key: "catalog-product-created-#{@product.id}",
          action: "catalog.product.created",
          auditable_type: "Catalog::EventProduct",
          auditable_id: @product.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: @product.attributes.slice(
            "name", "description", "type", "status", "inventory_mode",
            "allow_custom_price", "sales_start_at", "sales_end_at",
            "min_per_order", "max_per_order", "schedule_change_refund_policy",
            "sort_order"
          ),
          metadata: { event_id: @event.id }
        )
      end
    end
  end
end
