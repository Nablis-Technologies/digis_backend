# frozen_string_literal: true

module Ticketing
  module AttendeeIndex
    # Returns only persisted attendee-index rows newer than the scanner cursor.
    # Tombstones are sorted before active additions so a scanner never exposes a
    # stale lookup row while applying one response transaction.
    class ChangesSince < Core::BaseService
      def initialize(event:, since:)
        @event = event
        @since = Integer(since)
      rescue ArgumentError, TypeError
        @since = nil
      end

      def call
        return failure(error(:scanner_cursors_required, :bad_request)) if @since.nil? || @since.negative?

        current = @event.attendee_index_version.to_i
        rows = Ticketing::AttendeeIndexEntry.where(event_id: @event.id)
          .where("index_version > ?", @since)
          .order(removed: :desc, index_version: :asc, id: :asc)
        success(
          version: current,
          changed: rows.map { |row| Ticketing::ScannerSyncSerializer.attendee_index_entry(row) }
        )
      end

      private

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner_sync.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
