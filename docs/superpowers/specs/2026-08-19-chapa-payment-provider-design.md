# Chapa Payment Provider Integration Design

## Goal

Connect the existing payment-provider boundary to Chapa's test/live API modes
without coupling Orders to Chapa payloads, exposing provider secrets, or
changing the immutable commercial and payment-state rules.

## Scope

This vertical slice covers inbound payment initialization and verification,
refund submission and verification, available-balance checks, and signed Chapa
webhooks. It persists only normalized provider evidence plus the buyer-safe
hosted checkout URL. Payout adapters remain separate domain boundaries and use
the deterministic fake during the Task 8 recovery drills; payout transport
integration is a separate follow-up.

## Architecture

`Payments::Providers::ChapaClient` owns Chapa HTTP, authentication, endpoint
paths, decimal-to-minor-unit conversion, response mapping, and HMAC validation.
`Payments::Providers::ChapaAdapter` remains the provider-neutral adapter used by
Orders. A boot initializer registers it only when `CHAPA_ENABLED=true` and all
required configuration is present. Preview deployments accept only `*_TEST`
Chapa keys; live mode requires an explicit non-preview environment.

The canonical `Payments::Providers::Result` gains an optional `checkout_url`.
The payment attempt stores that URL and the buyer-safe payment serializer
exposes it only to the authorized buyer. Raw Chapa payloads, API keys, webhook
secrets, and signature material are never persisted or logged.

## Configuration

The deployment supplies secrets through environment variables, never through
Git or seeds:

- `CHAPA_ENABLED`
- `CHAPA_MODE` (`test` or `live`)
- `CHAPA_SECRET_KEY`
- `CHAPA_WEBHOOK_SECRET`
- `CHAPA_API_BASE_URL` (defaults to Chapa's official API host)
- `CHAPA_CALLBACK_URL`
- `CHAPA_RETURN_URL`

Render's Blueprint declares the secret fields with `sync: false`; the values
are entered manually in the Render service environment. Chapa's dashboard
webhook URL is the deployed `/payments/chapa/webhook` endpoint and its secret
hash must match `CHAPA_WEBHOOK_SECRET`.

## Failure and security behavior

- Provider timeouts remain `unknown`/`timeout` and never become success.
- Browser redirects and callbacks never prove payment; the server verifies
  the transaction with Chapa before accepting it.
- Both documented Chapa signature headers are accepted only when one matches
  the HMAC-SHA256 digest of the exact raw body using constant-time comparison.
- HTTP errors, malformed responses, and missing provider references map to the
  existing normalized result boundary without leaking response bodies.
- Missing or invalid staging configuration fails closed at boot when Chapa is
  explicitly enabled; Chapa remains unregistered when disabled.

## Verification

Transport tests use an injected fake HTTP transport and prove request shape,
status mapping, minor-unit conversion, refund/balance mapping, HMAC handling,
and secret redaction. Payment model, service, serializer, configuration,
route, Postman, syntax, RuboCop, Zeitwerk, focused Rails tests, and the full
`N_PLUS_ONE=1` suite are run before the branch is handed back. Staging proof
then uses Chapa test mode for a real hosted checkout and webhook, while the
deterministic fake remains the tool for forced failure and liquidity drills.
