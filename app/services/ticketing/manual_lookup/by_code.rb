# frozen_string_literal: true

module Ticketing
  module ManualLookup
    # Resolves one exact, checksummed PNR from the event attendee index and
    # sends the resulting claims through the same admission transaction as QR.
    class ByCode < Base
      def initialize(raw_code:, **options)
        super(**options)
        @raw_code = raw_code
      end

      def call
        return failure(reason_error) if reason_error

        code = Core::LookupCodeService.validate(@raw_code)
        return failure(lookup_error(:invalid_lookup_code, :unprocessable_entity)) unless code

        entry = active_entries.find_by(lookup_code: code)
        unless entry
          record_lookup_audit!(lookup_via: "code", outcome: "not_found")
          return failure(lookup_error(:lookup_not_found, :not_found))
        end

        consume_entry(entry, lookup_via: "code")
      end

      private

      attr_reader :raw_code

      def reason_error
        valid_reason
      end
    end
  end
end
