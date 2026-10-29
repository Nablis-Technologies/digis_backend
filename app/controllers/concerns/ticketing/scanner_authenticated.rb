# frozen_string_literal: true

module Ticketing
  # Establishes the scanner session, operator, device, and event-assignment
  # context. It does not authorize a ticket, credential, or admission.
  module ScannerAuthenticated
    extend ActiveSupport::Concern

    included do
      skip_before_action :authenticate_user
      before_action :authenticate_scanner
    end

    attr_reader :current_scanner_device, :current_scanner_assignment, :current_scanner_operator

    private

    def authenticate_scanner
      event = Events::Event.find(params.require(:event_id))
      result = Ticketing::Scanners::AuthenticateSession.call(
        token: scanner_bearer_token,
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
      @current_scanner_operator = result.value.operator
    end

    def scanner_bearer_token
      authorization = request.headers["Authorization"].to_s
      return unless authorization.start_with?("Bearer ")

      authorization.delete_prefix("Bearer ").strip
    end
  end
end
