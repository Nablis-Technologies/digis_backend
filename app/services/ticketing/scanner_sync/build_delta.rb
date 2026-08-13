# frozen_string_literal: true

module Ticketing
  module ScannerSync
    # Builds an event-scoped delta from monotonic cursors. Every delta carries
    # the signing keys and all feed families so a connected scanner can apply
    # one atomic response without separately acknowledging each projection.
    class BuildDelta < BuildSnapshot
      REQUIRED_CURSORS = %i[revocations attendee_index schedule reversals].freeze

      def initialize(assignment:, cursors:)
        super(assignment:)
        @cursors = cursors.respond_to?(:to_h) ? cursors.to_h.transform_keys(&:to_sym) : {}
      end

      def call
        payload = nil
        Events::Event.transaction do
          event = Events::Event.lock.find(assignment.event_id)
          cursors = normalize_cursors
          return failure(cursors) if cursors.is_a?(Core::Error)

          versions = current_versions(event)
          ahead = REQUIRED_CURSORS.find { |key| cursors.fetch(key) > versions.fetch(key) }
          return failure(scanner_error(:scanner_cursor_ahead, :bad_request)) if ahead

          reversal_rows = reversals(event, since: cursors.fetch(:reversals))
          payload = {
            contract_version: 1,
            event_id: event.id.to_s,
            sync_mode: "delta",
            versions: versions,
            signing_keys: Ticketing::Qr::Verifier.public_keys,
            package_revocations: {
              version: versions.fetch(:revocations),
              changed: package_revocations(event, since: cursors.fetch(:revocations)).map do |row|
                ScannerSyncSerializer.package_revocation(row)
              end
            },
            credential_revocations: {
              version: versions.fetch(:revocations),
              changed: credential_revocations(event, since: cursors.fetch(:revocations)).map do |row|
                ScannerSyncSerializer.credential_revocation(row)
              end
            },
            attendee_index: Ticketing::AttendeeIndex::ChangesSince.call(
              event:, since: cursors.fetch(:attendee_index)
            ).value,
            schedule: cursors.fetch(:schedule) < versions.fetch(:schedule) ?
              schedule_payload(event) : empty_schedule(versions.fetch(:schedule)),
            server_use_ids: admission_uses(
              event, ids: reversal_rows.map(&:admission_use_id)
            ).map { |row| ScannerSyncSerializer.admission_use(row) },
            admission_use_reversals: {
              version: versions.fetch(:reversals),
              changed: reversal_rows.map { |row| ScannerSyncSerializer.reversal(row) }
            }
          }
        end
        success(payload)
      rescue ActiveRecord::RecordNotFound
        failure(scanner_error(:event_not_found, :not_found))
      end

      private

      def normalize_cursors
        REQUIRED_CURSORS.index_with do |key|
          value = Integer(@cursors.fetch(key))
          raise ArgumentError if value.negative?

          value
        end
      rescue ArgumentError, KeyError, TypeError
        scanner_error(:scanner_cursors_required, :bad_request)
      end

      def empty_schedule(version)
        {
          version:,
          event_dates: [],
          access_zones: [],
          product_access_zones: [],
          scanner_assignment_zones: []
        }
      end
    end
  end
end
