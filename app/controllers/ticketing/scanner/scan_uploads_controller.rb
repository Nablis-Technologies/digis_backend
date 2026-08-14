# frozen_string_literal: true

module Ticketing
  module Scanner
    # Authenticates the scanner device and commits one bounded offline batch.
    # ProcessUpload owns replay semantics and reconciliation; this controller
    # only permits the transport contract and renders its result.
    class ScanUploadsController < Ticketing::ApplicationController
      include Ticketing::ScannerAuthenticated

      skip_authorization only: :create

      def create
        values = upload_params
        result = Ticketing::ScannerSync::ProcessUpload.call(
          assignment: current_scanner_assignment,
          operator: current_user,
          client_upload_id: values.fetch(:client_upload_id),
          scans: values.fetch(:scans, []),
          cursors: values.fetch(:cursors),
          received_at: Time.current
        )
        return render_business_error(result.error) if result.failure?

        render_success(:"ticketing.scanner.success.upload_processed", data: result.value)
      rescue ActionController::ParameterMissing, KeyError, ArgumentError, TypeError
        render_error(
          I18n.t("ticketing.scanner_sync.errors.scanner_upload_parameters_invalid"),
          status: :bad_request,
          code: "scanner_upload_parameters_invalid"
        )
      end

      private

      def upload_params
        params.require(:upload).permit(
          :client_upload_id,
          cursors: %i[revocations attendee_index schedule reversals],
          scans: %i[
            credential_id ticket_id credential_version product_access_id access_zone_id client_scan_id
            scanned_at result lookup_via reason_code identity_check_result identity_checked_by_id
          ]
        ).to_h.deep_symbolize_keys
      end
    end
  end
end
