# frozen_string_literal: true

module Core
  # Applies the existing failure-only authentication throttle to anonymous
  # guest endpoints and records failed responses so abuse cannot bypass it.
  module GuestRequestThrottling
    extend ActiveSupport::Concern

    included do
      around_action :with_guest_throttle
    end

    private

    def with_guest_throttle
      result = guest_throttle.call
      if result.success?
        yield
      else
        render_error(result.error.message, status: result.error.status_code, code: result.error.code)
      end
    ensure
      guest_throttle.record_failure if response&.status.to_i >= 400
    end

    def guest_throttle
      @guest_throttle ||= Core::AuthThrottle.new(
        identifier: guest_throttle_identifier,
        ip_address: request.remote_ip
      )
    end

    def guest_throttle_identifier
      params[:phone].presence ||
        params.dig(:rsvp, :phone).presence ||
        params.dig(:order, :phone).presence ||
        params.dig(:payment_attempt, :phone).presence ||
        params.dig(:payment_refresh, :phone).presence ||
        params[:id].presence || params[:token].presence || params[:ticket_view_token].presence
    end
  end
end
