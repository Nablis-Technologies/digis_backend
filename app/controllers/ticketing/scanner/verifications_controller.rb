# frozen_string_literal: true

module Ticketing
  module Scanner
    # Authenticates the scanner device and records one online QR admission.
    # The service owns credential validation and the atomic slot transaction;
    # this controller only resolves request-bound records and shapes JSON.
    class VerificationsController < Ticketing::ApplicationController
      include Ticketing::ScannerAuthenticated

      skip_authorization only: :create

      def create
        values = verification_params
        product_access = Catalog::ProductAccess.find(values.fetch(:product_access_id))
        access_zone = Events::AccessZone.find_by(id: values[:access_zone_id])
        return render_error(
          I18n.t("ticketing.scanner.errors.zone_not_found"),
          status: :unprocessable_entity,
          code: "zone_not_found"
        ) if values[:access_zone_id].present? && access_zone.nil?

        qr_result = Ticketing::Qr::Verifier.call(token: values.fetch(:qr_token))
        return render_business_error(qr_result.error) if qr_result.failure?

        result = Ticketing::Admissions::Consume.call(
          claims: qr_result.value,
          product_access:,
          assignment: current_scanner_assignment,
          access_zone:,
          client_scan_id: values.fetch(:client_scan_id),
          scanned_at: Time.zone.parse(values.fetch(:scanned_at).to_s),
          lookup_via: values.fetch(:lookup_via, "qr"),
          reason_code: values[:reason_code],
          identity_check: values[:identity_check],
          identity_checked_by: current_user
        )
        return render_business_error(result.error) if result.failure?

        checkin = result.value
        render_success(
          checkin.result == "success" ? :"ticketing.scanner.success.admission_recorded" :
            :"ticketing.scanner.success.admission_attempt_recorded",
          data: verification_payload(checkin)
        )
      rescue ActionController::ParameterMissing, KeyError, ArgumentError
        render_error(
          I18n.t("ticketing.scanner.errors.verification_parameters_invalid"),
          status: :bad_request,
          code: "verification_parameters_invalid"
        )
      rescue ActiveRecord::RecordNotFound
        render_error(
          I18n.t("ticketing.scanner.errors.product_access_not_found"),
          status: :not_found,
          code: "product_access_not_found"
        )
      end

      private

      def verification_params
        params.require(:verification).permit(
          :qr_token,
          :product_access_id,
          :access_zone_id,
          :client_scan_id,
          :scanned_at,
          :lookup_via,
          :reason_code,
          :identity_check
        ).to_h.symbolize_keys
      end

      def verification_payload(checkin)
        uses = checkin.admission_uses.order(:admission_slot_id, :usage_number)
        {
          id: checkin.id,
          client_scan_id: checkin.client_scan_id,
          result: checkin.result,
          credential_id: checkin.credential_id,
          product_access_id: checkin.product_access_id,
          event_date_id: checkin.event_date_id,
          admission_use_count: uses.length,
          admission_uses: uses.map do |use|
            { id: use.id, admission_slot_id: use.admission_slot_id, usage_number: use.usage_number }
          end
        }
      end
    end
  end
end
