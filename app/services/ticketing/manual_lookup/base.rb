# frozen_string_literal: true

require "digest"
require "securerandom"

module Ticketing
  module ManualLookup
    # Shared boundary for PNR, phone, and online help-desk lookup. A lookup may
    # identify a credential, but only Admissions::Consume can authorize or
    # consume it; lookup results therefore never become a ticket-level bypass.
    class Base < Core::BaseService
      REASON_CODES = %w[
        phone_dead no_qr_printout no_qr_sms app_crash no_connectivity forgot_code group_booking other
      ].freeze
      MAX_MATCHES = 25
      Result = Data.define(:status, :entry, :checkin, :matches)

      def initialize(
        event:, product_access: nil, assignment:, operator:, access_zone: nil,
        reason_code:, client_scan_id: nil, scanned_at: nil, identity_check: nil, request_id: nil
      )
        @event = event
        @product_access = product_access
        @assignment = assignment
        @operator = operator
        @access_zone = access_zone
        @reason_code = reason_code.to_s.strip.downcase
        @client_scan_id = client_scan_id
        @scanned_at = scanned_at
        @identity_check = identity_check
        @request_id = request_id
      end

      private

      attr_reader :event, :product_access, :assignment, :operator, :access_zone,
                  :reason_code, :client_scan_id, :scanned_at, :identity_check, :request_id

      def valid_reason
        return if REASON_CODES.include?(reason_code)

        lookup_error(:reason_code_required, :unprocessable_entity)
      end

      def consume_entry(entry, lookup_via:)
        return failure(lookup_error(:lookup_admission_parameters_required, :bad_request)) if
          client_scan_id.blank? || product_access.blank? || scanned_at.blank?

        claims = Ticketing::CredentialClaims.from_index_entry(
          entry,
          expires_at: product_access.event_date.ends_at
        )
        result = Ticketing::Admissions::Consume.call(
          claims:,
          product_access:,
          assignment:,
          access_zone:,
          client_scan_id:,
          scanned_at:,
          lookup_via:,
          reason_code:,
          identity_check:,
          identity_checked_by: operator,
          now: scanned_at
        )
        return audit_failure(result.error, entry:, lookup_via:) if result.failure?

        checkin = result.value
        record_audit!(
          entry:,
          lookup_via:,
          outcome: checkin.result,
          phase: "selection"
        )
        success(Result.new(status: checkin.result, entry:, checkin:, matches: []))
      rescue ArgumentError
        failure(lookup_error(:lookup_claims_invalid, :unprocessable_entity))
      end

      def audit_failure(error, entry:, lookup_via:)
        record_audit!(
          entry:,
          lookup_via:,
          outcome: error.code,
          phase: "selection"
        )
        failure(error)
      end

      def record_lookup_audit!(lookup_via:, outcome:, phase: "search", entry: nil)
        record_audit!(entry:, lookup_via:, outcome:, phase:)
      end

      def record_audit!(entry:, lookup_via:, outcome:, phase:)
        key_material = [
          assignment.id,
          operator&.id,
          lookup_via,
          phase,
          request_id || client_scan_id || SecureRandom.uuid
        ].join(":")
        Core::Audit::Record.call(
          audit_key: "ticketing-manual-lookup-#{Core::KeyedDigest.digest(
            namespace: "ticketing-scanner-manual-lookup",
            value: key_material
          )}",
          action: "ticketing.scanner.manual_lookup",
          auditable_type: assignment.class.name,
          auditable_id: assignment.id,
          actor_type: operator&.class&.name,
          actor_id: operator&.id,
          audited_changes: {
            event_id: event.id,
            credential_id: entry&.credential_id,
            lookup_via: lookup_via,
            reason_code: reason_code,
            outcome: outcome.to_s
          }.compact,
          metadata: {
            scanner_device_assignment_id: assignment.id,
            phase: phase
          }
        )
      end

      def active_entries
        Ticketing::AttendeeIndexEntry.active.where(event_id: event.id)
      end

      def minimal_match(entry)
        {
          credential_id: entry.credential_id,
          ticket_id: entry.ticket_id,
          lookup_code: entry.lookup_code,
          ticket_type: entry.ticket_type,
          ticket_type_label: entry.ticket_type_label,
          credential_mode: entry.credential_mode,
          slot_positions: Array(entry.slot_positions).map(&:to_i),
          entry_limit: entry.entry_limit,
          entry_validation_mode: entry.entry_validation_mode
        }.tap do |match|
          match[:holder_name] = entry.holder_name if entry.entry_validation_mode == "qr_and_id"
        end
      end

      def result_for_matches(status, entries)
        success(Result.new(
          status:,
          entry: nil,
          checkin: nil,
          matches: entries.first(MAX_MATCHES).map { |entry| minimal_match(entry) }
        ))
      end

      def phone_hash(raw_phone)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(raw_phone)
        return if normalized.blank?

        Digest::SHA256.hexdigest(normalized)
      end

      def lookup_error(key, status)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:
        )
      end
    end
  end
end
