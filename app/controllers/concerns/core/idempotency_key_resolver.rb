# frozen_string_literal: true

module Core
  # Resolves an idempotency key for a command using the Stripe/Shopify model:
  # the client owns retry semantics and MUST supply an `Idempotency-Key`
  # header. The server deduplicates replays of that key across client timeouts
  # and connection drops. There is deliberately NO fallback (no request_id, no
  # random UUID): a missing key means the request is rejected rather than
  # silently retried under a fresh value that defeats deduplication.
  module IdempotencyKeyResolver
    extend ActiveSupport::Concern

    private

    def idempotency_key
      request.headers["Idempotency-Key"].presence
    end

    def ensure_idempotency_key_present
      return if idempotency_key.present?

      render json: {
        error: I18n.t("idempotency.missing_key"),
        code: "missing_idempotency_key"
      }, status: :bad_request
    end
  end
end
