# Chapa V2 vs Digis Chapa V1: Deep Evaluation

**Date:** 2026-09-12  
**Scope:** buyer checkout, resale marketplace payouts, organizer payouts, future featured-listing payments, messaging-credit top-ups, split payments/subaccounts, and virtual accounts.

## Executive decision

Chapa V2 is worth adopting before we finish the payout implementation, but it
should be a deliberate provider-boundary migration rather than a base-URL swap.

The strongest V2 benefits for Digis are:

- direct-charge flows for known mobile-money methods;
- a documented asynchronous payout lifecycle with machine-readable states;
- native `Idempotency-Key` support;
- payout bank metadata and currency/limit information;
- bulk payout support for future organizer, affiliate, or vendor batches;
- virtual-account primitives that may support future wallet/credit products.

The current documentation does **not** explicitly prove that subaccount creation
or virtual-account deposit/deduction can be fully exercised with test keys. Those
capabilities must be confirmed with a V2 test key or Chapa support before we
make them dependencies of the design.

## Primary sources reviewed

- [V2 migration guide](https://docs.chapa.global/docs/v2/migration)
- [Test vs live mode](https://docs.chapa.global/docs/v2/integrations/test-live-mode)
- [Hosted payments](https://docs.chapa.global/docs/v2/integrations/accept-payment)
- [Direct charge](https://docs.chapa.global/docs/v2/direct-charge/initiate-payment)
- [Split payments](https://docs.chapa.global/docs/v2/integrations/split-payment)
- [Payouts](https://docs.chapa.global/docs/v2/payouts/payout)
- [Bulk payouts](https://docs.chapa.global/docs/v2/payouts/bulk-payout)
- [Payout bank list](https://docs.chapa.global/docs/v2/payouts/bank-list)
- [Virtual-account creation](https://docs.chapa.global/docs/v2/virtual-account/create-virtual-account)
- [Virtual-account deposits](https://docs.chapa.global/docs/v2/virtual-account/deposit-virtual-account)
- [Virtual-account deductions](https://docs.chapa.global/docs/v2/virtual-account/deduct-virtual-account)
- [V2 webhooks](https://docs.chapa.global/docs/v2/integrations/webhooks)

## What Digis used at evaluation baseline

The repository is V1-oriented:

- `render.yaml` defaults `CHAPA_API_BASE_URL` to `https://api.chapa.co/v1`.
- `Payments::Providers::ChapaClient` calls V1 transaction initialization,
  transaction verification, refund, refund verification, balance, and webhook
  contracts.
- `Finance::PayoutProviders::ChapaTransferClient` calls V1 `/transfers`,
  `/transfers/verify/:reference`, `/balances/:currency`, and `/banks`.
- V1 idempotency is carried through `tx_ref`/`reference` body fields. The
  client does not send Chapa's V2 `Idempotency-Key` header.
- `Marketplace::PayoutProviders::ChapaAdapter` intentionally uses the direct
  transfer contract and does not depend on provider recipient tokenization.
- Encrypted Digis payout accounts and the internal seller ledger remain the
  correct system of record; Chapa is an external payment/transfer rail.
- Messaging credit top-ups already reuse the normal payment adapter, so they
  can benefit from a V2 hosted or direct-charge client without changing the
  credit ledger semantics.

## V1 limitations relevant to Digis

### Hosted checkout only in the current client

The current payment client is built around V1
`POST /transaction/initialize`. There is no direct-charge implementation for
Telebirr, CBE Birr, or other known payment methods. V2 documents
`POST /v2/payments/direct`, which returns an authentication mode such as USSD,
PIN, OTP, or redirect and keeps the final payment state asynchronous.

This is the clearest user-experience improvement for mobile-first Ethiopian
checkout, box office, and future paid featured listings.

### Payout lifecycle is narrower

V1's current direct-transfer client maps a small set of generic statuses and
uses a single-recipient `/transfers` call. The V2 payout documentation defines
an asynchronous lifecycle including `pending`, `processing`, `success`,
`failed`, `blocked`, `auth_needed`, `otp_needed`, and `reversed`.

V2 also documents separate payout verification, payout webhooks, a processor
reference, and a payout-specific account object. The Digis payout state machine
should normalize these states instead of treating an initialization response as
final success.

### No native provider idempotency header

Digis already requires client idempotency keys at its own API boundary. V1
currently embeds those keys in provider references. V2 documents an
`Idempotency-Key` header for hosted payments, direct charge, payouts, bulk
payouts, and virtual-account mutations. That aligns much better with Digis's
retry and reconciliation model.

### No bulk payout contract

The current V1 client dispatches one transfer at a time. V2 bulk payouts accept
multiple payout items, return a batch reference, and track each item
independently. Partial success is explicit: successful items must not be rolled
back just because another item failed.

This is valuable for future organizer/affiliate/vendor settlement, but resale
seller payouts should initially remain one payout intent per seller so each
ledger allocation and reversal remains independently auditable.

### No virtual-account primitive

V1 has no virtual-account API. V2 documents creation, retrieval, deposit,
deduction, and credit/debit history. This could support a future organizer
wallet, campaign-credit treasury, cashless-event balance, or escrow-like
product.

It should not replace Digis's internal double-entry ledger. A virtual account
would be a provider-side balance/rail; Digis still needs its own immutable
commercial, order, credit, payout, and reconciliation facts.

## What V2 does **not** solve automatically

### V2 payouts still send beneficiary details

The V2 payout example accepts an account object containing `account_name`,
`account_number`, and `bank_slug`. V2 therefore does not eliminate Digis's need
for encrypted beneficiary storage, destination verification policy, masking, or
secure decryption only at the provider boundary.

### Split payments are not resale settlement

V2 split payments create/reuse a subaccount and pass split rules during
`POST /v2/payments/hosted`. The split occurs when the buyer's payment is
initialized. That is suitable for a primary ticket sale where an organizer is
paid as part of checkout.

It is not the natural model for a resale sale that occurs later, after Digis
has already issued and owns the ticket lifecycle. Using split payments for
resale would move settlement timing and refund responsibility into the original
pay-in, weakening Digis's control of resale ledger facts and payout policy.

### Test-mode support needs proof for subaccounts and virtual accounts

The V2 test/live page explicitly says test mode can exercise hosted checkout,
direct charge, payouts, refunds, and webhooks, with `CHAPA_TEST_...` keys and no
real money. The split-payment and virtual-account pages document endpoints and
examples, but the reviewed pages do not explicitly guarantee that subaccount
creation, virtual-account deposits, or virtual-account deductions are all
available and fully simulated in test mode.

Therefore:

- treat V2 payout test mode as documented and testable;
- treat V2 hosted/direct payment test mode as documented and testable;
- treat subaccount and virtual-account test support as **unverified** until a
  real V2 test-key smoke drill or written Chapa confirmation succeeds.

This supersedes the older repository note that stated V2 subaccounts were
definitively test-mode supported without preserving a live test-key transcript.

## Product fit by Digis use case

| Digis use case | V2 fit | Recommendation |
| --- | --- | --- |
| Primary ticket checkout | Strong | Migrate hosted checkout contract; add direct charge for known mobile methods later. |
| Resale marketplace pay-in | Strong | Use hosted/direct pay-in, but keep Digis resale fulfillment and ledger as the source of truth. |
| Immediate resale seller payout | Strong | Use single V2 payout after payment verification/fulfillment; track asynchronous states and reversals. |
| Organizer payouts | Strong | Use single payout now; add bulk payouts when batch settlement is needed. |
| Featured listing purchase | Strong | Model as a normal paid order/line item and use the same V2 payment boundary. |
| Messaging-credit top-up | Strong | Use hosted/direct payment; keep credit grant behind accepted-payment evidence. |
| Split payment for primary organizer settlement | Conditional | Evaluate commercially and legally; it changes holds, refunds, settlement, and ledger responsibility. |
| Split payment for resale | Poor fit | Do not use as the default resale payout mechanism. |
| Virtual accounts | Future option | Consider for a wallet/credit treasury only after test-mode support, custody, and reconciliation are proven. |

## Recommended architecture

Do not make every domain know Chapa V1 or V2 paths. Introduce versioned provider
clients behind the existing canonical adapter contracts:

1. `Payments::Providers::ChapaV2Client` for hosted, direct charge, verify,
   refunds, and webhook signature normalization.
2. `Finance::PayoutProviders::ChapaV2Client` for single payout, bulk payout,
   payout verification, bank list, and provider capabilities.
3. A shared V2 webhook ingress that verifies the exact raw-body HMAC, records
   `webhook_type`, `event`, `status`, `mode`, `merchant_reference`,
   `chapa_reference`, and a deduplication key, then enqueues domain processing.
4. A normalized internal status map that preserves V2-specific states such as
   `blocked`, `auth_needed`, `otp_needed`, and `reversed` rather than collapsing
   them into generic failure.
5. Versioned configuration and credentials. V2 documents the same host base
   URL (`https://api.chapa.global`) with environment selected by
   `CHAPA_TEST_...` versus `CHAPA_LIVE_...` keys. The current V1 key/config
   contract cannot be assumed compatible.
6. Bank-slug and capability snapshots with currency/min/max validation before a
   payout request. Keep Digis account-number encryption and HMAC digests.
7. A resale payout job that creates an internal payout intent after resale
   fulfillment, dispatches one V2 payout, and reconciles asynchronously. Do
   not couple payout success to the buyer ticket issuance transaction.
8. A bulk payout orchestration layer later for organizer/affiliate batches. It
   must persist batch and item references and support partial success.

## Required V2 proof before implementation

Obtain a V2 test key and run a disposable smoke matrix:

1. Hosted payment: success, failed, cancelled, incomplete, blocked, and
   auth-needed states.
2. Direct charge: Telebirr and CBE Birr test flows, authentication completion,
   timeout, and verification.
3. Single payout: accepted/pending, success, failed, blocked, reversed,
   auth-needed, OTP-needed, verification, and same-key retry.
4. Bulk payout: accepted batch, item-level partial success, failed item retry,
   and duplicate batch retry.
5. Bank list: ET bank/currency limits and inactive-bank handling.
6. Split payment: subaccount creation, reuse, payment initialization, refund,
   and whether all of this works with a test key.
7. Virtual account: create, duplicate idempotent create, deposit, deduction,
   insufficient balance, and credit/debit history—with test-mode confirmation.
8. Webhooks: raw-body signature validation, duplicate delivery, out-of-order
   transitions, `mode` separation, payout reversal, and partial refund.

## Final recommendation

Migrate toward V2 before implementing the final payout workflow. V2 is worth it
for the direct-charge UX, payout state model, idempotency header, bank
capabilities, and bulk settlement.

Do not make V2 split payments the resale architecture, and do not introduce
virtual accounts until the test-mode contract and custody model are proven.
Keep Digis's internal ledgers, encrypted payout destinations, fulfillment
boundary, and reconciliation state machine regardless of which Chapa features
are enabled.

The next engineering task should be a **V2 provider contract and test-mode
spike**, not a production payout endpoint or a broad rewrite.
