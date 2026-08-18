# frozen_string_literal: true

module Ticketing
  module Scanner
    # Handles scanner recovery lookups. Device/operator authentication remains
    # in ScannerAuthenticated; each lookup service owns its stricter help-desk
    # authorization, reason-code, audit, and shared admission boundaries.
    class LookupsController < Ticketing::ApplicationController
      include Ticketing::ScannerAuthenticated

      skip_authorization only: :create

      def create
        values = lookup_params
        product_access = Catalog::ProductAccess.find(values[:product_access_id]) if values[:product_access_id].present?
        access_zone = Events::AccessZone.find_by(id: values[:access_zone_id])
        return render_error(
          I18n.t("ticketing.scanner.errors.zone_not_found"),
          status: :unprocessable_entity,
          code: "zone_not_found"
        ) if values[:access_zone_id].present? && access_zone.nil?

        result = lookup_service(values, product_access:, access_zone:).call
        return render_business_error(result.error) if result.failure?

        render_success(
          :"ticketing.scanner.success.lookup_completed",
          data: lookup_payload(result.value)
        )
      rescue ActionController::ParameterMissing, KeyError, ArgumentError
        render_error(
          I18n.t("ticketing.scanner.errors.lookup_parameters_invalid"),
          status: :bad_request,
          code: "lookup_parameters_invalid"
        )
      rescue ActiveRecord::RecordNotFound
        render_error(
          I18n.t("ticketing.scanner.errors.product_access_not_found"),
          status: :not_found,
          code: "product_access_not_found"
        )
      end

      private

      def lookup_params
        params.require(:lookup).permit(
          :method,
          :query,
          :selected_credential_id,
          :product_access_id,
          :access_zone_id,
          :client_scan_id,
          :scanned_at,
          :reason_code,
          :identity_check
        ).to_h.symbolize_keys
      end

      def lookup_service(values, product_access:, access_zone:)
        common = {
          event: current_scanner_assignment.event,
          product_access:,
          assignment: current_scanner_assignment,
          operator: current_user,
          access_zone:,
          reason_code: values[:reason_code],
          client_scan_id: values[:client_scan_id],
          scanned_at: values[:scanned_at].present? ? Time.zone.parse(values[:scanned_at].to_s) : nil,
          identity_check: values[:identity_check],
          request_id: values[:client_scan_id].presence || request.uuid
        }

        case values.fetch(:method).to_s
        when "code"
          Ticketing::ManualLookup::ByCode.new(raw_code: values.fetch(:query), **common)
        when "phone"
          Ticketing::ManualLookup::ByPhone.new(
            raw_phone: values.fetch(:query),
            selected_credential_id: values[:selected_credential_id],
            **common
          )
        when "online"
          Ticketing::ManualLookup::OnlineSearch.new(
            query: values.fetch(:query),
            selected_credential_id: values[:selected_credential_id],
            **common
          )
        else
          raise ArgumentError
        end
      end

      def lookup_payload(result)
        {
          status: result.status,
          matches: result.matches,
          checkin: result.checkin && result.checkin.serialized_result
        }.compact
      end
    end
  end
end
