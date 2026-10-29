# frozen_string_literal: true

module Catalog
  module Organizer
    # Organizer product projection. Pricing belongs to the product while
    # ticket type, access, and inventory data remain explicit read-only facets.
    class EventProductSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :event_id, :name, :description, :type, :status, :inventory_mode,
                 :allow_custom_price, :sales_start_at, :sales_end_at, :min_per_order,
                 :max_per_order, :schedule_change_refund_policy, :sort_order, :metadata,
                 :lock_version, :created_at, :updated_at, :ticket_type, :pricing,
                 :product_accesses, :inventory

      def ticket_type
        type = object.ticket_type
        return unless type

        {
          id: type.id,
          event_product_id: type.event_product_id,
          approval_mode: type.approval_mode,
          audience: type.audience,
          date_selection: type.date_selection,
          delegation_enabled: type.delegation_enabled,
          entry_validation_mode: type.entry_validation_mode,
          transferable: type.transferable,
          admissions_per_unit: type.admissions_per_unit,
          resale_enabled: type.resale_enabled,
          waitlist_enabled: type.waitlist_enabled
        }
      end

      def pricing
        {
          options: object.prices.sort_by { |price| [ price.currency, price.amount_minor, price.active_from ] }
            .map { |price| Catalog::ProductPriceSerializer.new(price).attributes }
        }
      end

      def product_accesses
        object.product_accesses.sort_by { |access| [ access.event_date.starts_at, access.id ] }.map do |access|
          {
            id: access.id,
            type: access.type,
            required_access_protection: access.required_access_protection,
            usage_limit: access.usage_limit,
            opens_offset_seconds: access.opens_offset_seconds,
            closes_offset_seconds: access.closes_offset_seconds,
            event_date: Events::Organizer::EventDateSerializer.new(access.event_date).attributes
          }
        end
      end

      def inventory
        {
          mode: object.inventory_mode,
          pools: object.inventories.sort_by { |pool| [ pool.event_date_id.to_s, pool.id ] }.map do |pool|
            {
              id: pool.id,
              event_date_id: pool.event_date_id,
              capacity: pool.capacity,
              held_count: pool.held_count,
              sold_count: pool.sold_count,
              available_count: pool.available_quantity,
              lock_version: pool.lock_version
            }
          end
        }
      end
    end
  end
end
