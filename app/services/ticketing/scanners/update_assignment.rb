# frozen_string_literal: true

module Ticketing
  module Scanners
    # Replaces a paired scanner's zone/time scope atomically and advances the
    # event schedule cursor so the next scanner delta contains the new zones.
    class UpdateAssignment < Core::BaseService
      Result = Data.define(:assignment, :replayed) do
        def replayed? = replayed
      end

      ZONE_MODES = %w[all_current_zones selected_zones].freeze

      def initialize(assignment:, actor:, zone_mode:, zone_ids:, starts_at: nil, ends_at: nil,
        idempotency_key:, at: Time.current)
        @assignment = assignment
        @actor = actor
        @zone_mode = zone_mode.to_s
        @zone_ids = Array(zone_ids).compact.map(&:to_s).uniq.sort
        @starts_at_input = starts_at
        @ends_at_input = ends_at
        @idempotency_key_input = idempotency_key
        @at = at
      end

      def call
        key = idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        event = Events::Event.find(assignment.event_id)
        return failure(error(:assignment_forbidden, :forbidden)) unless authorized?(event)
        starts_at = parse_time(starts_at_input, assignment.starts_at)
        ends_at = parse_time(ends_at_input, assignment.ends_at)
        return failure(error(:assignment_window_invalid, :unprocessable_entity)) if invalid_window?(starts_at, ends_at)
        return failure(error(:zone_invalid, :unprocessable_entity)) unless zone_mode.in?(ZONE_MODES)
        return failure(error(:zone_invalid, :unprocessable_entity)) if zone_mode == "all_current_zones" && zone_ids.any?
        return failure(error(:event_cancelled, :conflict)) if event.status.in?(%w[cancelled completed])

        digest = request_digest(starts_at:, ends_at:)
        result = nil
        ActiveRecord::Base.transaction do
          event.lock!
          locked = Ticketing::ScannerDeviceAssignment.lock.find(assignment.id)
          replay = replay_result(locked, key:, digest:)
          if replay
            result = replay
            next
          end
          unless locked.event_id == event.id && locked.event_staff_assignment.role == "scanner" && locked.active?
            result = failure(error(:assignment_inactive, :conflict))
            next
          end

          zones = resolve_zones(event)
          if zones.is_a?(Core::BusinessError)
            result = failure(zones)
            next
          end

          locked.update!(starts_at:, ends_at:)
          locked.assignment_zones.delete_all
          zones.each do |zone|
            Ticketing::ScannerAssignmentZone.create!(
              scanner_device_assignment: locked,
              access_zone: zone
            )
          end
          Ticketing::ScannerSession.where(scanner_device_assignment_id: locked.id, revoked_at: nil)
            .update_all(expires_at: ends_at, updated_at: at)
          bump_result = Events::Schedule::BumpVersion.call(event:)
          raise bump_result.error if bump_result.failure?
          write_audit!(locked, key:, digest:, zone_ids: zones.map(&:id), starts_at:, ends_at:)
          result = success(Result.new(assignment: locked, replayed: false))
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(error(:assignment_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_assignment, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :assignment, :actor, :zone_mode, :zone_ids, :starts_at_input,
                  :ends_at_input, :idempotency_key_input, :at

      def idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def authorized?(event)
        Events::AuthorizationResolver.can_assign?(actor, event, "scanner")
      end

      def parse_time(value, fallback)
        return fallback if value.blank?
        return value.in_time_zone if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def invalid_window?(starts_at, ends_at)
        starts_at.blank? || ends_at.blank? || starts_at >= ends_at || ends_at <= at
      end

      def resolve_zones(event)
        return event.access_zones.where(active: true).order(:sort_order, :id).to_a if zone_mode == "all_current_zones"
        return [] if zone_ids.empty?

        zones = Events::AccessZone.where(id: zone_ids, event_id: event.id, active: true).to_a
        return error(:zone_invalid, :unprocessable_entity) unless zones.length == zone_ids.length

        zones
      end

      def request_digest(starts_at:, ends_at:)
        value = {
          assignment_id: assignment.id,
          actor_id: actor.id,
          zone_mode:,
          zone_ids:,
          starts_at: starts_at.iso8601(6),
          ends_at: ends_at.iso8601(6)
        }
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-assignment-update-request",
          value: ActiveSupport::JSON.encode(value)
        )
      end

      def audit_key(key)
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-assignment-update-key/#{assignment.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def replay_result(locked, key:, digest:)
        audit = Core::AuditLog.find_by(audit_key: audit_key(key))
        return unless audit

        return failure(error(:idempotency_conflict, :conflict)) unless
          audit.metadata.deep_stringify_keys["request_digest"] == digest

        success(Result.new(assignment: locked, replayed: true))
      end

      def write_audit!(locked, key:, digest:, zone_ids:, starts_at:, ends_at:)
        locked.record_audit!(
          "ticketing.scanner_device_assignment.scope_updated",
          actor:,
          audit_key: audit_key(key),
          audited_changes: { starts_at: starts_at.iso8601, ends_at: ends_at.iso8601 },
          metadata: { request_digest: digest, zone_mode:, access_zone_ids: zone_ids.map(&:to_s) }
        )
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key.to_s,
          status:,
          errors:
        )
      end
    end
  end
end
