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

      # Rendered through Core::JsonResponse so the body is the standard
      # `{ success: false, error:, code: }` envelope. A bare hash here would be
      # unreadable to every envelope-aware client, which would fall back to the
      # HTTP status text and show the user "Bad Request".
      render_error(
        I18n.t("idempotency.missing_key"),
        status: :bad_request,
        code: "missing_idempotency_key"
      )
    end
  end
end
