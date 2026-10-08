# frozen_string_literal: true

module Ticketing
  # Exposes organization-admin scanner credential lifecycle operations. The
  # commands own authorization, locking, audit history, and state transitions.
  class ScannerDevicesController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :set_organization, only: :index
    before_action :set_device, except: :index
    before_action :ensure_idempotency_key_present, only: :revoke

    def index
      scope = policy_scope(@organization.scanner_devices).order(:created_at, :id)
      authorize @organization.scanner_devices.new, :index?, policy_class: Ticketing::ScannerDevicePolicy

      render_success(
        data: scope,
        serializer_options: { serializer: Ticketing::ScannerDeviceSerializer }
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

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def set_device
      @device = Ticketing::ScannerDevice.find(params[:id])
    end
  end
end
