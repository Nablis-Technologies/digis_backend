# frozen_string_literal: true

module Messaging
  # Unauthenticated provider ingress; verification and deduplication live in
  # the inbound suppression command, not in the controller.
  class CampaignWebhooksController < Messaging::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: :create

    def create
      guard = Campaigns::AbuseGuard.call(
        scope: "inbound:#{params.require(:provider)}",
        identity: request.remote_ip,
        limit: 120
      )
      return render_error(guard.error.message, status: guard.error.status_code, code: guard.error.code) if guard.failure?

      result = Campaigns::Suppressions::ProcessInbound.call(
        provider: params.require(:provider),
        channel: params[:channel].presence || "sms",
        raw_body: request.raw_post,
        headers: request.headers.to_h
      )
      return render_error(result.error.message, status: result.error.status_code, code: result.error.code) if result.failure?

      render_success(
        data: { id: result.value.id, status: result.value.status },
        status: :accepted
      )
    rescue JSON::ParserError
      render_error(I18n.t("messaging.errors.inbound_payload_invalid"), status: :bad_request,
        code: "inbound_payload_invalid")
    end
  end
end
