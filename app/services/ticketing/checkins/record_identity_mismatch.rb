# frozen_string_literal: true

module Ticketing
  module Checkins
    # Records an online identity mismatch as an immutable admission attempt.
    # The later manager correction is a separate append-only check-in and never
    # edits or adds an admission use to this mismatch row.
    class RecordIdentityMismatch < Core::BaseService
      def initialize(
        ticket:, credential:, credential_version:, product_access:, event_date:, assignment:,
        client_scan_id:, scanned_at:, identity_checked_by:, lookup_via: "qr", access_zone: nil,
        reason_code: nil, scan_upload: nil, received_at: Time.current
      )
        @attributes = {
          ticket:,
          credential:,
          credential_version:,
          product_access:,
          event_date:,
          assignment:,
          client_scan_id:,
          scanned_at:,
          lookup_via:,
          access_zone:,
          reason_code:,
          scan_upload:,
          identity_checked_by:,
          received_at:
        }
      end

      def call
        return failure(error(:identity_checker_required, :unprocessable_entity)) unless @attributes[:identity_checked_by]

        result = Ticketing::Checkins::RecordAttempt.call(
          ticket: @attributes[:ticket],
          credential: @attributes[:credential],
          credential_version: @attributes[:credential_version],
          product_access: @attributes[:product_access],
          event_date: @attributes[:event_date],
          assignment: @attributes[:assignment],
          client_scan_id: @attributes[:client_scan_id],
          result: "identity_mismatch",
          scanned_at: @attributes[:scanned_at],
          lookup_via: @attributes[:lookup_via],
          access_zone: @attributes[:access_zone],
          reason_code: @attributes[:reason_code],
          scan_upload: @attributes[:scan_upload],
          identity_check_result: "mismatch",
          identity_checked_by: @attributes[:identity_checked_by],
          received_at: @attributes[:received_at]
        )
        return failure(result.error) if result.failure?

        success(result.value)
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          error(
            :identity_mismatch_invalid,
            :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      end

      private

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
