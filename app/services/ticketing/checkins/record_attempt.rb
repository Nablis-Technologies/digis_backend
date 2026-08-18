# frozen_string_literal: true

module Ticketing
  module Checkins
    # Appends one immutable check-in attempt. Admission uses are deliberately
    # created by the enclosing admission transaction so failed attempts and
    # successful group consumption share one atomic decision boundary.
    class RecordAttempt < Core::BaseService
      def initialize(
        ticket:, credential:, credential_version: credential.credential_generation.version,
        product_access:, event_date:, assignment:, client_scan_id:, result:, scan_upload: nil,
        scanned_at:, lookup_via:, access_zone: nil, reason_code: nil,
        identity_check_result: "not_required", identity_checked_by: nil, received_at: Time.current,
        overrides_checkin_log: nil, identity_override_by: nil, identity_override_reason: nil,
        identity_overridden_at: nil
      )
        @attributes = {
          ticket:,
          credential:,
          credential_version:,
          product_access:,
          event_date:,
          access_zone:,
          scanner_device_assignment: assignment,
          scan_upload:,
          client_scan_id:,
          result:,
          lookup_via:,
          reason_code:,
          identity_check_result:,
          identity_checked_by:,
          overrides_checkin_log:,
          identity_override_by:,
          identity_override_reason:,
          identity_overridden_at:,
          scanned_at:,
          received_at:
        }
      end

      def call
        success(Ticketing::CheckinLog.create!(@attributes))
      end
    end
  end
end
