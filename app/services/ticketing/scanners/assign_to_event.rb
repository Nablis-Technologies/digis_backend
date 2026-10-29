# frozen_string_literal: true

module Ticketing
  module Scanners
    # Creates the event/device binding from the invitation's durable grant.
    # Events owns the human role; Ticketing owns device scope and zone mappings.
    class AssignToEvent < Core::BaseService
      ZONE_MODES = %w[all_current_zones selected_zones].freeze

      def initialize(scanner_device:, event:, event_staff_assignment:, delegated_grant:, zone_mode:, zone_ids: [],
        starts_at:, ends_at:)
        @scanner_device = scanner_device
        @event = event
        @event_staff_assignment = event_staff_assignment
        @delegated_grant = delegated_grant
        @zone_mode = zone_mode.to_s
        @zone_ids = Array(zone_ids).compact.map(&:to_s).uniq
        @starts_at = parse_time(starts_at)
        @ends_at = parse_time(ends_at)
        @invalid_window = [ starts_at, ends_at ].any?(&:present?) &&
          (starts_at.present? && @starts_at.nil? || ends_at.present? && @ends_at.nil?)
      end

      def call
        return failure(error(:assignment_forbidden, :forbidden)) unless delegated_grant&.valid_for?(
          event:, role: "scanner"
        )
        return failure(error(:assignment_invalid, :unprocessable_entity)) unless staff_assignment_valid?
        return failure(error(:assignment_window_invalid, :unprocessable_entity)) if invalid_window
        return failure(error(:assignment_window_invalid, :unprocessable_entity)) if starts_at.blank? || ends_at.blank?
        return failure(error(:zone_invalid, :unprocessable_entity)) unless zone_mode.in?(ZONE_MODES)
        return failure(error(:zone_invalid, :unprocessable_entity)) if zone_mode == "all_current_zones" && zone_ids.any?
        return failure(error(:device_scope_forbidden, :forbidden)) unless device_in_event_scope?

        assignment = nil
        result = nil
        ActiveRecord::Base.transaction do
          event.lock!
          scanner_device.lock!
          zones = resolve_zones
          if zones.is_a?(Core::BusinessError)
            result = failure(zones)
            raise ActiveRecord::Rollback
          end

          assignment = Ticketing::ScannerDeviceAssignment.create!(
            scanner_device:,
            event:,
            event_staff_assignment:,
            assigned_by: grantor,
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
            actor: grantor,
            audited_changes: { event_id: event.id, event_staff_assignment_id: event_staff_assignment.id,
                               access_zone_ids: zones.map(&:id) },
            metadata: { grant_source_id: delegated_grant.source_id }
          )
        end

        result || success(assignment)
      rescue ActiveRecord::RecordNotUnique
        failure(error(:assignment_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_assignment, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :scanner_device, :event, :event_staff_assignment, :delegated_grant,
                  :zone_mode, :zone_ids, :starts_at, :ends_at, :invalid_window

      def grantor
        @grantor ||= Core::User.find(delegated_grant.grantor_id)
      end

      def staff_assignment_valid?
        event_staff_assignment.present? && event_staff_assignment.event_id == event.id &&
          event_staff_assignment.role == "scanner" && event_staff_assignment.active?
      end

      def device_in_event_scope?
        return true if scanner_device.organization_id == event.organization_id

        Events::EventOrganization.where(
          event_id: event.id,
          organization_id: scanner_device.organization_id,
          status: "active"
        ).exists?
      end

      def resolve_zones
        return event.access_zones.where(active: true).order(:sort_order, :id).to_a if
          zone_mode == "all_current_zones"
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
