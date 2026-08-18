# frozen_string_literal: true

module Ticketing
  # Establishes scanner device and event-assignment context for scanner
  # controllers. It does not authorize a ticket, credential, or admission.
  module ScannerAuthenticated
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_scanner
    end

    attr_reader :current_scanner_device, :current_scanner_assignment

    private

    def authenticate_scanner
      event = Events::Event.find(params.require(:event_id))
      result = Ticketing::Scanners::Authenticate.call(
        operator: current_user,
        device_identifier: params[:device_identifier],
        token: request.headers["X-Scanner-Token"],
        event:
      )
      return assign_scanner_context(result) if result.success?

      render_error(
        result.error.message,
        status: result.error.status,
        code: result.error.code,
        errors: result.error.errors
      )
    end

    def assign_scanner_context(result)
      @current_scanner_device = result.value.device
      @current_scanner_assignment = result.value.assignment
    end
  end
end
