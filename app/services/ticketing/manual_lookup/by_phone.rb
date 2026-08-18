# frozen_string_literal: true

module Ticketing
  module ManualLookup
    # Resolves canonical E.164 phone hashes against both holder and commercial
    # owner projections. Multiple tickets are returned for explicit selection;
    # no admission is attempted until a credential row is selected.
    class ByPhone < Base
      def initialize(raw_phone:, selected_credential_id: nil, **options)
        super(**options)
        @raw_phone = raw_phone
        @selected_credential_id = selected_credential_id
      end

      def call
        return failure(reason_error) if reason_error

        digest = phone_hash(@raw_phone)
        return failure(lookup_error(:invalid_phone, :unprocessable_entity)) unless digest

        entries = active_entries
          .where("phone_hash = :digest OR owner_phone_hash = :digest", digest:)
          .order(:lookup_code)
          .to_a
        return not_found if entries.empty?

        entry = selected_entry(entries)
        return entry if entry.is_a?(Core::BaseService::Result)
        return result_for_matches("multiple_matches", entries) if entry.nil?

        consume_entry(entry, lookup_via: "phone")
      end

      private

      attr_reader :raw_phone, :selected_credential_id

      def reason_error
        valid_reason
      end

      def selected_entry(entries)
        if selected_credential_id.present?
          selected = entries.find { |entry| entry.credential_id.to_s == selected_credential_id.to_s }
          return selected if selected

          return failure(lookup_error(:lookup_selection_invalid, :unprocessable_entity))
        end

        return entries.first if entries.one?

        record_lookup_audit!(lookup_via: "phone", outcome: "multiple_matches")
        nil
      end

      def not_found
        record_lookup_audit!(lookup_via: "phone", outcome: "not_found")
        failure(lookup_error(:lookup_not_found, :not_found))
      end
    end
  end
end
