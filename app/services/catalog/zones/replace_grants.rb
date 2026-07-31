# frozen_string_literal: true

module Catalog
  module Zones
    # Atomically replaces the zone grants for a single venue/parking product
    # access row. Guards:
    # - only draft products may be changed (active/retired are immutable);
    # - when any active zone exists for the access's event/date/type, at least
    #   one zone must be granted — an empty mapping never means "all zones".
    class ReplaceGrants < Core::BaseService
      def initialize(product_access:, zone_ids:)
        @product_access = product_access
        @zone_ids = Array(zone_ids).compact.uniq
      end

      def call
        ActiveRecord::Base.transaction do
          @product_access.lock!
          validate_draft_product!
          validate_zone_count!

          @product_access.product_access_zones.destroy_all
          @zone_ids.each do |zone_id|
            @product_access.product_access_zones.create!(access_zone_id: zone_id)
          end

          success(@product_access.reload)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def validate_draft_product!
        return if @product_access.event_product&.status == "draft"

        raise Core::Error, I18n.t("catalog.product_access_zone.errors.replace_forbidden")
      end

      def validate_zone_count!
        return unless @zone_ids.empty? && zone_active_for_event?

        raise Core::Error, I18n.t("catalog.product_access_zone.errors.zone_required")
      end

      # Zones are per event + date + type. A zone with a null event_date_id is
      # reusable across all event dates, so it also counts for a date-scoped
      # access (spec §6.13).
      def zone_active_for_event?
        event = @product_access.event_product&.event
        event_date = @product_access.event_date
        return false if event.blank?

        scope = Events::AccessZone.where(event:, type: @product_access.type).active
        scope = scope.where(event_date_id: [ nil, event_date.id ]) if event_date.present?
        scope.exists?
      end
    end
  end
end
