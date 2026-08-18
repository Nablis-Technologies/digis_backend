# frozen_string_literal: true

module Ticketing
  module Zones
    # Applies the event, date, access-type, product-grant, and scanner-grant
    # boundaries before an admission command can use a zone. An empty mapping
    # never broadens access: active zones require an explicit grant on both
    # sides, while an event with no active zones permits only a nil zone.
    class AuthorizeAdmission < Core::BaseService
      def initialize(assignment:, product_access:, access_zone: nil, now: Time.current)
        @assignment = assignment
        @product_access = product_access
        @access_zone = access_zone
        @now = now
      end

      def call
        return failure(error(:access_type_forbidden, :unprocessable_entity)) unless access_type_allowed?
        return failure(error(:assignment_event_mismatch, :unprocessable_entity)) unless same_event?
        return failure(error(:wrong_zone, :unprocessable_entity)) if access_zone && !valid_zone_shape?

        active_zones = active_zones_for_access
        if active_zones.exists?
          return failure(error(:zone_required, :unprocessable_entity)) if access_zone.nil?
          return failure(error(:wrong_zone, :unprocessable_entity)) unless active_zones.where(id: access_zone.id).exists?
          return failure(error(:wrong_zone, :unprocessable_entity)) unless product_zone_granted?
          return failure(error(:wrong_zone, :unprocessable_entity)) unless assignment_zone_granted?
        elsif access_zone.present?
          return failure(error(:wrong_zone, :unprocessable_entity))
        end

        success({ assignment:, product_access:, access_zone: })
      end

      private

      attr_reader :assignment, :product_access, :access_zone, :now

      def access_type_allowed?
        product_access.type.in?(%w[venue parking])
      end

      def same_event?
        assignment.event_id == product_access.event_product.event_id
      end

      def valid_zone_shape?
        access_zone.event_id == assignment.event_id &&
          access_zone.type == product_access.type &&
          access_zone.active? &&
          (access_zone.event_date_id.nil? || access_zone.event_date_id == product_access.event_date_id)
      end

      def active_zones_for_access
        Events::AccessZone
          .where(event_id: assignment.event_id, type: product_access.type, active: true)
          .where(event_date_id: [ nil, product_access.event_date_id ])
      end

      def product_zone_granted?
        Catalog::ProductAccessZone.exists?(product_access_id: product_access.id, access_zone_id: access_zone.id)
      end

      def assignment_zone_granted?
        Ticketing::ScannerAssignmentZone.exists?(
          scanner_device_assignment_id: assignment.id,
          access_zone_id: access_zone.id
        )
      end

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:
        )
      end
    end
  end
end
