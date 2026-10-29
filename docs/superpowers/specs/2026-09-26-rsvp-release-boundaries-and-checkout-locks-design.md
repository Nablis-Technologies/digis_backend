# RSVP Release Boundaries and Checkout Locking

Date: 2026-09-26  
Status: Approved by user 2026-09-26; resale fulfillment lock order refined after reproducing a PostgreSQL deadlock  
Related: G-27, G-29, G-34; follow-up to `2026-09-26-rsvp-audience-proof-release-design.md`

## Goal

Remove the Ticketing-to-Orders dependency from buyer registration release,
make checkout release acquire its shared advisory lock before row locks, and
retain the existing public release endpoint and lifecycle semantics.

## User-visible contract

Keep `POST /registrations/:id/release`, authentication, the required
`Idempotency-Key` header, authorization semantics, response status/body, and
`Ticketing::RegistrationSerializer` projection unchanged. Do not add or remove
request fields, database columns, or migrations.

## Current problem

`Ticketing::Registrations::ReleasePending` currently queries and locks
`Orders::OrderItem`, `Orders::Order`, and `Orders::Payment`, owns payment-state
knowledge, and calls `Orders::ReleaseCheckout`. This conflicts with the
documented dependency direction (`Orders` may depend on `Ticketing`; not the
reverse) and makes the release path's transactional orchestration span both
modules in the wrong direction.

The operation also needs one lock order. Buyer release and final expiry use the
`orders-checkout` transaction advisory lock, but generic `Orders::ReleaseCheckout`
does not acquire it. Marketplace cancellation/expiry call it after taking
listing/order locks, and resale reservation currently takes its listing/order
locks before the key. More importantly, checkout creation locks Event before
the key while payment attempt/acceptance lock Order before Event. Combined with
a release holding the checkout key while waiting for Order, these orders admit
an Event → key → Order → Event cycle. The key must therefore be acquired before
Event, Order, and Payment locks in event checkout/payment flows, not merely
added at the `ReleaseCheckout` boundary. Resale fulfillment adds one necessary
exception: it locks the relevant Ticketing ticket type before the checkout key
because resale cancellation/expiry already serialize in that order; the key
then precedes Order/Event/Payment/listing locks. Payment acceptance, grace
reconciliation, webhook application, and direct fulfillment must use that same
order for resale orders.

There are also small maintainability findings: duplicated proof-reference and
transition-key handling in `AudienceProof::Release`/`Reacquire`, and implicit
lookup-mode validation duplicated by `AccessCodes::Consume` and
`Invitations::Claim`. The suggestion to move proof mutations onto models is
not accepted as a requirement: `update!` is an ActiveRecord write, not raw SQL,
and these audited lifecycle commands are the right place for orchestration and
transaction-scoped proof transitions.

## Chosen architecture

Use the Orders-owned `Orders::ReleaseBuyerRegistration` command as the
coordinator for the HTTP release flow. Move the release action to an Orders
controller while preserving the existing URL. The controller loads the
Ticketing registration, applies its existing `release?` policy, and delegates
to the Orders command.

Add narrow `Orders::CheckoutLock` helpers that delegate to the existing
`Core::Database::AdvisoryLock`. `acquire!` centralizes the key name/arguments;
`acquire_for_order!` preflights order identity, locks linked ticket types first
for resale orders (or supplied ticket-type IDs for direct resale fulfillment),
then acquires the checkout key. Neither helper owns a transaction.

The Orders command owns one transaction and performs the cross-domain sequence:

1. Read immutable registration identity needed for the shared key, then acquire
   `orders-checkout(buyer_id, event_id)` before any relevant row lock.
2. Lock all linked orders in deterministic ID order, then payment rows whose
   statuses block a buyer release, also deterministically. Keep the existing
   blocking set (`created`, `processing`, `succeeded`, `unknown`, `timeout`)
   owned by `Orders::Payment`, not Ticketing.
3. Revalidate ownership and registration state under lock. Reject paid or
   payment-in-progress checkouts using the same typed errors as today. A
   cancelled registration replay returns success before paid/in-flight checks,
   matching the current no-op replay behavior.
4. Close the eligible active checkout using the already-locked path in
   `Orders::ReleaseCheckout` with `buyer_requested`; do not reacquire the same
   Order/Payment row locks.
5. Call a Ticketing-only registration transition that changes
   `pending_payment` to `cancelled`, releases its stored audience proof, and
   writes the existing registration/proof audits.

The whole sequence remains atomic. Exact replays remain no-ops, and failed
checkout release, proof compensation, or audit persistence rolls everything
back. The Ticketing leaf command must not query Orders, know payment statuses,
or acquire the checkout advisory lock.

`Orders::ReleaseCheckout.call` becomes safe when called directly: it obtains the
same checkout advisory lock before its own order row lock, using a read-only
identity lookup before the transaction's first checkout row lock. Add a
transaction-scoped `call_locked` entry point for callers that already hold the
checkout key and required Order/Payment locks; it must not issue duplicate row
locks and must roll back its own mutations on failure. Checkout
creation acquires the shared key before Event/replay/order locks. Payment-attempt
creation/result persistence acquire it before Order/Event/Payment locks.
Payment acceptance, grace reconciliation, event-payment application, and
resale fulfillment lock Ticketing ticket types before the key for resale, then
acquire the key before Order/Event/Payment/listing locks; non-resale payments
remain key-first. The payment-event inbox may keep its own `PaymentEvent` lock
first, but obtains the appropriate ticket-type/key sequence before changing an
event-payment row; no checkout release path locks the inbox. These rules prevent
a payment transition from holding an Order/Event row while a release waits on it
and align resale success with expiry/cancellation.

Marketplace resale reservation and policy disablement first serialize on the
Ticketing ticket-type row, then acquire the buyer/event checkout key, then take
listing/order locks. Policy disablement enumerates candidate listing IDs and
reservation identities without locks, sorts and atomically acquires all
buyer/event keys, then delegates listing transitions; it must not hold listing
locks while waiting for checkout keys. Direct cancellation/expiry lock the
ticket type, preflight reservation identity without locks, acquire the key,
then lock/revalidate listing/order state. Nested acquisitions of the same
transaction-scoped PostgreSQL advisory key are permitted; distinct buyer/event
keys in one command are sorted and acquired atomically.

## Focused cleanup

- Extract shared `AudienceProof` proof-reference resolution and transition-key
  digest parsing only where it removes real duplication without hiding the
  distinct release/reacquire error codes.
- Reuse `Ticketing::Registrations::Support::Halt` for result-carrying aborts if
  its contract remains suitable; do not add another exception wrapper.
- Replace the two `@invalid_lookup` implementations with an explicit shared or
  local lookup-mode predicate. It must reject missing input, both modes at
  once, wrong-class records, and present-but-unsaved associated records. A
  plain XOR of raw-value presence and record-ID presence is insufficient
  unless it also validates the record argument itself.
- Keep underflow, invitation status/expiry/claimant checks, locking, and audit
  behavior in the explicit proof lifecycle command. Do not add model methods
  merely to avoid `update!` calls.

## Invariants and failure behavior

- Checkout advisory lock precedes Order, Event, Payment, and Registration row
  locks in event-backed checkout/payment flows. `CreateCheckout` takes the key
  before Event; `StartPaymentAttempt` takes it before Order/Event/Payment.
  Resale payment acceptance, grace reconciliation, and fulfillment take the
  TicketType row(s) before the key, then acquire the key before Order/Event/
  Payment/listing rows. `ProcessPaymentEvent` may lock its inbox row first, then
  follows the matching payment path before changing an event Payment.
- Checkout advisory lock also precedes marketplace listing locks where they
  conflict with that checkout.
- For resale policy changes, lock the ticket type before the buyer/event
  checkout key; then acquire the checkout key before the resale listing/order.
  `ConfigureTicketTypeResale` must not lock listing rows before it delegates to
  `CancelListing`.
- Registration release lock order is advisory → linked orders by ID → blocking
  payments by ID → registration → proof row.
- `Orders::ReleaseCheckout` may call Ticketing; Ticketing release code must not
  call Orders.
- Marketplace flows preserve listing/ticket state transitions and idempotent
  replay while following the same checkout lock protocol.
- No raw access code or invitation token enters audit data or logs.
- The existing buyer-release, payment-in-progress, paid-order, and replay result
  contracts remain unchanged.
- No new route shape, database migration, or backwards-compatibility layer.

## Validation

Add regression coverage for the unchanged HTTP route/authorization/idempotency
contract; the Orders-owned orchestration and rollback paths; order → blocking
payment → registration row-lock order; direct `ReleaseCheckout` lock placement;
and concurrent release/expiry/resale/checkout actions. Retain the existing
proof-release, reconsideration, restart, and final-expiry coverage. Run the
affected cross-flow suite both normally and with `N_PLUS_ONE=1`, scoped RuboCop,
Zeitwerk, Postman JSON parsing, and `git diff --check`.

## Out of scope

- Reorganizing all pre-existing Ticketing-to-Orders references elsewhere in
  refunds, fulfillment, or package issuance. This change removes the new
  dependency introduced by buyer release and does not claim to complete a
  repository-wide module-boundary migration.
- Changing the public registration-release behavior or G-29/G-34 product rules.
- Render deployment or preview E2E verification.
