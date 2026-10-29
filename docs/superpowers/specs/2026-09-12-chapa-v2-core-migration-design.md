# Chapa V2 Core Migration Design

**Date:** 2026-09-12  
**Status:** Approved scope: core-first migration

## Goal

Replace Digis's Chapa V1 payment and payout contracts with Chapa V2 while
preserving the existing order, immutable-ledger, resale-fulfillment, credit,
and reconciliation domain interfaces.

## Scope

Included:

- hosted payment initialization and verification;
- Direct Charge as a provider capability for a known payment method;
- refunds and refund verification;
- V2 payout initialization and verification;
- V2 payout bank-list capabilities;
- V2 webhook signature and event normalization;
- provider-native idempotency headers;
- V2 status normalization for pending, processing, blocked, auth-needed,
  OTP-needed, reversed, failed, and success states;
- Render/test configuration and Postman contract updates.

Deferred behind a separate capability spike:

- split-payment subaccounts as a primary-settlement model;
- virtual accounts, deposits, deductions, and wallet custody;
- payment cancellation remains explicitly deferred while the registered
  provider capability is `cancel: false`;
- any dependency on undocumented V2 test-mode behavior for those features.

## Architecture

Provider paths remain behind deep adapters. `Payments::Providers::ChapaClient`
owns V2 pay-in/refund HTTP details and returns the existing canonical payment
result. `Finance::PayoutProviders::ChapaPayoutClient` owns V2 single-payout,
bank-list, and verification details and returns the existing canonical payout
result. Marketplace payout registration continues to reuse the Finance payout
client through its adapter, while Marketplace retains its encrypted destination
and ledger invariants. Both clients use the shared generic Core transport and
exact JSON-number value object; the domain adapters remain separate.

The migration is a clean V2 cutover for this development branch: no runtime V1
fallback, no V1/V2 branching in domain services, and no provider payloads leak
past the adapter seams. Existing internal idempotency keys remain the Digis
replay identity and V2 `Idempotency-Key` header; Chapa merchant references are
separate deterministic values bounded to the provider's 20-character limit.

## Provider contracts

### Hosted payment

`POST /v2/payments/hosted` receives an integer minor-unit amount, currency,
unique provider-safe `merchant_reference` (20 characters or fewer), nested
customer details, configured callback and return URLs, and internal metadata.
The redirect fields are supported and retained for UX compatibility, although
the public documentation describes them as optional. A successful
initialization is still `pending` and only returns a checkout URL; payment
verification remains required before value is delivered.

### Direct charge

`POST /v2/payments/direct` is exposed through the payment adapter as a
capability-driven operation. It returns `auth_type`, `request_id`, provider
reference, and an initial pending state. Direct charge is not forced into the
hosted flow; existing callers can continue using hosted checkout until a
payment method is selected explicitly.

### Payout

`POST /v2/payouts` receives amount, currency, account details, merchant
reference, reason, metadata, and the `Idempotency-Key` header. A successful
response creates an asynchronous payout; it is not final settlement. V2
verification and webhook events update the existing payout state machine.

Bulk payouts are deferred. The V2 endpoint returns batch and item-level state,
so it will not be exposed until Digis has a typed batch result and durable item
reconciliation model.

### Webhooks

The V2 webhook handler verifies `x-chapa-signature` as HMAC-SHA256 over the exact
raw body before JSON parsing, records `mode`, `webhook_type`, `event`, status,
merchant reference, Chapa reference, processor reference, and metadata, and
lets existing durable inbox/outbox processing remain idempotent.

## Data and security invariants

- Amounts remain integer minor units inside Digis and are sent unchanged as
  exact JSON integers at the V2 provider boundary. A fractional ETB price such
  as `5.13` is sent as `513`; Digis does not divide, round, or reinterpret the
  integer at the provider boundary.
- Encrypted payout account fields remain the only storage for raw beneficiary
  values; V2 payout requests decrypt only at dispatch time.
- V2 references and webhook event IDs are stored as reconciliation evidence.
- Test/live mode is explicit and validated against `CHAPA_TEST_...` or
  `CHAPA_LIVE_...` credentials.
- The internal Digis ledger remains authoritative for resale proceeds,
  organizer balances, credit grants, refunds, and payout allocations.

## Verification gates

Before declaring the migration complete:

1. Local contract tests pass for hosted, direct, refund, payout, verification,
   bank list, headers, payloads, and all normalized status states.
2. A V2 test-key smoke drill passes hosted success/failure/cancel/incomplete,
   direct-charge pending/auth flow, payout pending/success/failure/reversal,
   webhook duplicate/out-of-order handling, and same-key retries.
3. Render preview runs the same smoke drill without exposing provider secrets.
4. No V1 endpoint strings, V1 key-prefix validation, or V1-only response
   assumptions remain in the runtime provider implementation.
5. Split/virtual-account work is documented as deferred unless real V2 test-mode
   evidence is captured.
