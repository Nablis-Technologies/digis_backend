# Marketplace Immediate Resale Withdrawals

**Status:** Approved for implementation on 2026-10-02. This supersedes the
resale-availability timing exclusions in
`2026-09-10-marketplace-seller-payout-direct-transfer-design.md`; organizer
payout maturity is unchanged.

## Product rule

After the buyer's payment is accepted and `Marketplace::FulfillSale` atomically
transfers the ticket, the seller's net resale proceeds are available to
withdraw immediately. Availability is not delayed until the event ends or for
Finance's seven-day organizer-payout maturity buffer. The seller initiates a
withdrawal; the system does not automatically pay out every resale.

"Immediately" means proceeds are eligible and Chapa dispatch is queued
promptly. It does not promise immediate bank credit: Chapa payouts are
asynchronous and remain pending/processing until provider verification confirms
completion.

## Seller withdrawal contract

- Add seller-owned payout collection, show, and create routes under
  `/marketplace/seller/payouts`.
- Require the standard `Idempotency-Key` on create.
- Require `currency`; accept optional positive integer `amount_minor` (omitted
  means all currently withdrawable net proceeds for that seller/currency) and
  optional seller-owned verified
  `seller_payout_account_id` (omitted means the seller's verified default Chapa
  destination).
- Payout creation nets all currently available ledger facts for the seller and
  currency across events. A negative resale reversal therefore offsets later
  proceeds for that seller, including proceeds from another event.
- `GET /marketplace/seller/balance` remains the source for this seller-wide
  currency balance.
- The server authorizes only the authenticated seller's own ledger facts,
  payout destination, and payout records. Responses never expose bank details,
  raw provider payloads, or raw idempotency keys.
- Building a payout reserves signed immutable ledger allocations under the
  seller/currency lock. A transactional outbox event dispatches the
  pending payout through `Marketplace::DispatchSellerPayoutJob`; the HTTP
  request never waits on Chapa.
- On success, append payout debit ledger facts split across the source events
  represented by the payout's positive allocations; those debit facts sum
  exactly to the payout amount.
- Replaying the same key and payload returns the original payout. Reusing the
  key with a different currency, amount, or explicit account returns `409
  idempotency_conflict`.

## Marketplace ledger policy

- New `resale_proceeds` and marketplace-fee entries use fulfillment time as
  `available_at`; they do not inherit Finance event-maturity policy.
- Positive payout-eligible Marketplace facts are `resale_proceeds`, positive
  `cancellation_reversal`, and positive `adjustment`. Negative ledger facts
  (including fees, chargebacks, reversals, and negative adjustments) offset
  proceeds before a payout is built.
- Chapa payout success consumes allocations and writes the payout debit;
  definite failure releases allocations; timeout/unknown remains processing
  and follows provider reconciliation, never blind resubmission.
- If a refund/reversal arrives after money has been paid out, append the
  existing negative seller-ledger fact. It reduces the seller's balance and
  offsets future proceeds. It cannot recall funds already delivered to a bank;
  any remainder remains an explicit negative seller balance for operator
  visibility. Do not debit another seller or silently erase the debt.
- Chapa's current payout adapter declares the balance API unsupported. The
  implementation must not invent a balance endpoint or claim immediate bank
  settlement; provider insufficient-balance or blocked results remain in the
  payout lifecycle and use existing reconciliation/status handling.

## Architecture and scope

- Marketplace owns its signed-ledger eligibility rules; it must not inherit
  Finance's organizer `POSITIVE_TYPES` or event-maturity helper.
- Remove the obsolete maturity-fanout and build jobs. A seller request creates
  the payout intent synchronously in the database; a transactional outbox
  queues only the dispatch job.
- Preserve Chapa V2 transport, payout-account encryption/verification, the
  shared provider reserve policy where provider balance is available, and
  payout-result reconciliation.
- Do not add an admin payout-creation route, schema migration, automatic payout
  after every sale, organizer payout changes, live credential changes, or a
  real-money transfer in this implementation.
- Existing immutable ledger rows retain their stored `available_at`; the new
  timing applies to new resale ledger entries. No ledger rewrite/backfill is
  performed.

## Acceptance criteria

1. A seller with a verified default destination can request payout of an
   accepted resale while the event is not completed.
2. Payout amount equals gross resale proceeds less Marketplace fee and available
   negative/reversal facts; partial requests cannot exceed net proceeds.
3. No default/unverified destination, another seller's account, invalid amount,
   currency mismatch, or insufficient net proceeds creates a payout or outbox
   dispatch event.
4. Exact idempotent replay returns one payout and one request audit/outbox
   event; changed-payload replay conflicts.
5. A successful request reserves ledger facts, publishes a durable outbox event,
   and enqueues Chapa dispatch. Chapa's initial pending result is never shown as
   successful bank delivery.
6. Provider failure releases allocations; timeout/unknown remains reconcilable;
   provider success consumes allocations and appends payout ledger facts.
7. A later chargeback/reversal creates a negative seller balance that offsets
   later proceeds across the seller's events without rewriting historical
   ledger rows; payout debit entries still sum to the provider payout and retain
   source-event attribution.
8. The seven-day organizer maturity rule and organizer payout path remain
   unchanged.
