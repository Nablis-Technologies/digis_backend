# frozen_string_literal: true

require "json"

module Orders
  # Unauthenticated provider callback endpoint. Provider authentication is
  # delegated to RecordPaymentEvent; this action only parses the body, invokes
  # that one command, and acknowledges the durable inbox row.
  class PaymentWebhooksController < Orders::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: :create

    def create
      payload = JSON.parse(request.raw_post.presence || "{}")
      result = Orders::RecordPaymentEvent.call(
        provider: params.require(:provider),
        provider_event_id: payload["event_id"] || payload["id"] || request.headers["X-Provider-Event-Id"],
        event_type: payload["event_type"] || payload["type"],
        payload:,
        raw_payload: request.raw_post,
        signature: request.headers["X-Provider-Signature"],
        headers: request.headers.to_h
      )
      return render_service_result(result) if result.failure?

      event = result.value
      render_success(
        I18n.t("orders.payments.webhooks.received"),
        data: { id: event.id, provider_event_id: event.provider_event_id, status: event.status },
        status: :accepted
      )
    rescue JSON::ParserError
      render_error(
        I18n.t("orders.payments.webhooks.errors.invalid_webhook_payload"),
        status: :bad_request, code: "invalid_webhook_payload"
      )
    end
  end
end
