# frozen_string_literal: true

module Ticketing
  module Scanner
    # Authenticates a scanner using the signed-in operator JWT plus the
    # event-scoped scanner credential supplied in X-Scanner-Token.
    class AuthController < Ticketing::ApplicationController
      include Ticketing::ScannerAuthenticated

      skip_authorization only: :create

      def create
        render_success(
          :"ticketing.scanner.success.authenticated",
          data: {
            device_id: current_scanner_device.id,
            assignment_id: current_scanner_assignment.id,
            event_id: current_scanner_assignment.event_id,
            status: current_scanner_assignment.status,
            starts_at: current_scanner_assignment.starts_at,
            ends_at: current_scanner_assignment.ends_at
          }
        )
      end
    end
  end
end
