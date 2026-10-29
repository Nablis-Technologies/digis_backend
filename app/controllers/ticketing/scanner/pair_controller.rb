# frozen_string_literal: true

module Ticketing
  module Scanner
    # Exchanges an event-owned invitation capability for a scoped scanner
    # session. This is the only scanner endpoint that is intentionally public.
    class PairController < Ticketing::ApplicationController
      before_action :ensure_idempotency_key_present
      skip_before_action :authenticate_user, only: :create
      skip_authorization only: :create

      def create
        response.headers["Cache-Control"] = "no-store, private"
        result = Ticketing::Scanners::PairInvitation.call(
          pairing_token: pairing_params[:pairing_token],
          pairing_code: pairing_params[:pairing_code],
          pairing_method: pairing_params[:pairing_method],
          installation_id: pairing_params[:installation_id],
          device_name: pairing_params[:device_name],
          ip_address: request.remote_ip,
          idempotency_key:
        )
        return render_business_error(result.error) if result.failure?

        render_success(
          :"ticketing.scanner.success.paired",
          data: pairing_payload(result.value),
          status: result.value.replayed? ? :ok : :created
        )
      end

      private

      def pairing_params
        params.permit(:pairing_token, :pairing_code, :pairing_method, :installation_id, :device_name)
          .to_h.symbolize_keys
      end

      def pairing_payload(result)
        invitation = result.invitation
        assignment = result.session.scanner_device_assignment
        zones = assignment.assignment_zones.includes(:access_zone).map(&:access_zone)

        {
          scanner_session_token: result.scanner_session_token,
          replayed: result.replayed?,
          event: { id: invitation.event_id, title: invitation.event.title },
          device: { id: assignment.scanner_device_id, name: assignment.scanner_device.name },
          assignment: {
            id: assignment.id,
            status: assignment.status,
            starts_at: assignment.starts_at,
            ends_at: assignment.ends_at
          },
          zones: zones.map { |zone| { id: zone.id, name: zone.name } },
          expires_at: result.session.expires_at
        }
      end
    end
  end
end
