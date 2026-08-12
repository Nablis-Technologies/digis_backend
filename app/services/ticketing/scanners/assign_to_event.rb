# frozen_string_literal: true

module Ticketing
  module Scanners
    # Creates the event-scoped authorization for a registered device. The
    # organization boundary and explicit zone mappings are enforced before the
    # assignment and its mappings are committed together.
    class AssignToEvent < Core::BaseService
      def initialize(scanner_device:, event:, actor:, zone_ids: [], starts_at: nil, ends_at: nil)
        @scanner_device = scanner_device
        @event = event
        @actor = actor
        @zone_ids = Array(zone_ids).compact.map(&:to_s).uniq
        @starts_at = parse_time(starts_at)
        @ends_at = parse_time(ends_at)
        @invalid_window = [ starts_at, ends_at ].any?(&:present?) &&
          (starts_at.present? && @starts_at.nil? || ends_at.present? && @ends_at.nil?)
      end

      def call
        return failure(error(:assignment_forbidden, :forbidden)) unless Events::AuthorizationResolver.can_assign?(
          actor, event, "scanner"
        )
        return failure(error(:assignment_window_invalid, :unprocessable_entity)) if invalid_window
        return failure(error(:device_scope_forbidden, :forbidden)) unless device_in_event_scope?

        zones = resolve_zones
        return failure(zones) if zones.is_a?(Core::BusinessError)

        assignment = nil
        ActiveRecord::Base.transaction do
          scanner_device.lock!
          assignment = Ticketing::ScannerDeviceAssignment.create!(
            scanner_device:,
            event:,
            assigned_by: actor,
            starts_at:,
            ends_at:
          )
          zones.each do |zone|
            Ticketing::ScannerAssignmentZone.create!(
              scanner_device_assignment: assignment,
              access_zone: zone
            )
          end
          assignment.record_audit!(
            "ticketing.scanner_device_assignment.created",
            actor:,
            audited_changes: { event_id: event.id, access_zone_ids: zones.map(&:id) }
          )
        end

        success(assignment)
      rescue ActiveRecord::RecordNotUnique
        failure(error(:assignment_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_assignment, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :scanner_device, :event, :actor, :zone_ids, :starts_at, :ends_at, :invalid_window

      def device_in_event_scope?
        return true if scanner_device.organization_id == event.organization_id

        Events::EventOrganization.where(
          event_id: event.id,
          organization_id: scanner_device.organization_id,
          status: "active"
        ).exists?
      end

      def resolve_zones
        return [] if zone_ids.empty?

        zones = Events::AccessZone.where(id: zone_ids, event_id: event.id, active: true).to_a
        return error(:zone_invalid, :unprocessable_entity) unless zones.length == zone_ids.length

        zones
      end

      def parse_time(value)
        return value if value.blank? || value.is_a?(Time)

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
