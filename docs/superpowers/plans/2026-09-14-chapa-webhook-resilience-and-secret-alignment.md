# Chapa Webhook Signature Verification & Resilience Plan

## Task Overview
The user created a new Chapa account where checkout is working, but incoming webhooks to `https://digis-backend-preview.onrender.com/payments/chapa/webhook` are returning `HTTP 401 Unauthorized`.

End-to-end live testing confirmed:
1. Chapa successfully delivered a live webhook (`User-Agent: ChapaWebhook/1.0`, IP: `13.42.83.12`) for test payment `HCwhi5LnQ8RY` (`amount: 106`, `merchant_reference: ecf0cdc5a957ab5a6e75`).
2. Digis diagnostic logging recorded:
   ```text
   [CHAPA-WEBHOOK-DIAGNOSTIC] signature_present=true signature_length=64 expected_length=64 raw_payload_bytes=465 content_length=465 signature_headers=x-chapa-signature raw_webhook_secret_match=false canonical_webhook_secret_match=false raw_api_secret_match=false canonical_api_secret_match=false
   ```
3. Root cause:
   - **Secret Mismatch**: Chapa computes the HMAC-SHA256 signature using the "Secret Hash" configured in the Chapa Dashboard (**Settings -> Webhooks**). Because a new Chapa account was created, the Secret Hash in the Chapa Dashboard does not match `CHAPA_WEBHOOK_SECRET` on Render.
   - **Code Rigidity**: `ChapaClient#verify_webhook` strictly checked a single secret (`@webhook_secret`) against only the raw payload string, and only read the `x-chapa-signature` header (ignoring Chapa's documented `chapa-signature` header and API secret key fallback).

---

## User Action Required (Environment & Dashboard Alignment)

> [!IMPORTANT]
> To ensure Chapa webhooks verify successfully, the secret in Chapa's Dashboard and Render must be identical:
> 1. **Chapa Dashboard**:
>    - Go to **Settings > Webhooks** (or Profile > Webhooks).
>    - Ensure the Webhook URL is set to:
>      `https://digis-backend-preview.onrender.com/payments/chapa/webhook`
>    - Look at the **Secret Hash** field. If it is empty, generate or type a secure secret (e.g. `chapa_webhook_secret_2026`). Click **Save**.
> 2. **Render Dashboard**:
>    - Go to **digis-backend-preview > Environment**.
>    - Ensure `CHAPA_WEBHOOK_SECRET` is set to the **exact same Secret Hash** configured in step 1.
>    - Ensure `CHAPA_SECRET_KEY` is set to your new account's `CHAPA_TEST_...` secret key.
>    - Save/deploy changes.

---

## Proposed Code Changes

### Component 1: Webhook Controller Signature Resolution
#### [MODIFY] [`app/controllers/orders/payment_webhooks_controller.rb`](file:///Users/adoniyas/Documents/Projects/Rails/digis_backend/app/controllers/orders/payment_webhooks_controller.rb)
- Support both `X-Chapa-Signature` and `Chapa-Signature` headers:
  ```ruby
  signature = request.headers["X-Chapa-Signature"].presence || request.headers["Chapa-Signature"]
  ```

### Component 2: ChapaClient Resilient Webhook Verification
#### [MODIFY] [`app/services/payments/providers/chapa_client.rb`](file:///Users/adoniyas/Documents/Projects/Rails/digis_backend/app/services/payments/providers/chapa_client.rb)
- Accept signatures from both `x-chapa-signature` and `chapa-signature` headers.
- Evaluate candidate signatures across:
  1. `@webhook_secret` with raw payload
  2. `@webhook_secret` with canonical JSON (`JSON.generate(parsed_payload)`)
  3. `@secret_key` with raw payload (as documented in Chapa SDKs)
  4. `@secret_key` with canonical JSON
- Update `log_webhook_signature_diagnostic` to output safe, masked hints (lengths, truncated 2-character prefixes/suffixes) so any secret misconfiguration is immediately identifiable in Render logs without exposing secrets.

### Component 3: Test Suite Alignment
#### [MODIFY] [`test/services/payments/providers/chapa_client_test.rb`](file:///Users/adoniyas/Documents/Projects/Rails/digis_backend/test/services/payments/providers/chapa_client_test.rb)
- Update test to verify that canonical JSON signatures are accepted.
- Add test verifying fallback to `chapa-signature` header and API secret key.
#### [MODIFY] [`test/controllers/orders/payment_webhooks_controller_test.rb`](file:///Users/adoniyas/Documents/Projects/Rails/digis_backend/test/controllers/orders/payment_webhooks_controller_test.rb)
- Add test verifying `Chapa-Signature` header is extracted and passed to the adapter.

---

## Verification Plan

### Automated Tests
- Run `bin/rails test test/services/payments/providers/chapa_client_test.rb`
- Run `bin/rails test test/controllers/orders/payment_webhooks_controller_test.rb`
- Run `bin/rails test test/services/orders/process_payment_event_test.rb`
- Run `bundle exec rubocop -A`

### Live End-to-End Verification
- Deploy changes to `feat/launch-hardening-telemetry` on Render.
- Verify that a test checkout initiated on Render Preview and paid via the hosted checkout URL receives the webhook, verifies the signature, records the `PaymentEvent`, and transitions the order to paid.
