# frozen_string_literal: true

module Ticketing
  # Exposes organization-admin scanner credential lifecycle operations. The
  # commands own authorization, locking, audit history, and state transitions.
  class ScannerDevicesController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :set_device
    before_action :ensure_idempotency_key_present

    def rotate_token
      result = Ticketing::Scanners::RotateToken.call(
        device: @device, actor: current_user, idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        result.value.replayed? ? :"ticketing.scanner.success.token_rotation_replayed" :
          :"ticketing.scanner.success.token_rotated",
        data: { scanner_device: result.value.device, token: result.value.token },
        serializer_options: {
          scanner_device: { serializer: Ticketing::ScannerDeviceSerializer }
        }
      )
    end

    def revoke
      result = Ticketing::Scanners::RevokeDevice.call(
        device: @device,
        actor: current_user,
        reason: params.require(:reason),
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::ScannerDeviceSerializer }
      )
    rescue ActionController::ParameterMissing
      render_error(
        :"ticketing.scanner.errors.revoke_reason_required",
        status: :bad_request,
        code: "revoke_reason_required"
      )
    end

    private

    def set_device
      @device = Ticketing::ScannerDevice.find(params[:id])
    end
  end
end
