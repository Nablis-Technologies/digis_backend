# RSVP Audience Proof Release and Reacquisition

Date: 2026-09-26  
Status: Approved by user 2026-09-26; G-29 index resolution approved 2026-09-26  
Related gaps: G-29, G-34; builds on G-27

## Goal

Return an access-code use or invitation claim when a registration is definitively
released, rejected, or expired, while ensuring the old registration cannot
still complete without its proof and every compensation/reacquisition is
atomic, auditable, and exactly once.

## Context

G-27 now consumes access-code quantity or claims an invitation in the same
transaction that creates a registration. Replays do not consume twice. The
remaining asymmetry is that later lifecycle transitions can end a registration
without returning that proof.

The checkout expiry path currently closes an order while leaving its linked
registration in `pending_payment`. Returning proof at that point without also
ending the registration would leave a payable registration that no longer owns
the consumed proof. Therefore final checkout expiry must expire its linked
pending registrations in the same transaction as proof restoration. A checkout
restart before final expiry is not a terminal transition and keeps the existing
registration and proof intact.

## Approved behavior

| Terminal transition | Proof action | Registration behavior |
|---|---|---|
| Buyer releases a pending registration | Return its access-code quantity, or reopen its still-valid invitation | `pending_payment` → `cancelled` |
| Organizer rejects a pending-approval registration | Return its access-code quantity, or reopen its still-valid invitation | `pending_approval` → `rejected` |
| Checkout is finally released as expired | Return proof for each linked pending registration | `pending_payment` → `expired` |

Each proof action and its registration/order transition must commit or roll back
together. The existing settlement-grace/provider verification workflow remains
authoritative: merely reaching the initial checkout deadline does not return
proof while that workflow is retaining the checkout. Compensation occurs only
when `Orders::ReleaseCheckout` actually finalizes expiry. A later provider
success continues through the existing reversal path.

## Proof restoration rules

- Access-code use is returned by `registration.package_quantity`, under a row
  lock on the code. The service must fail closed if the counter is lower than
  the amount being returned; it must not underflow or silently repair drift.
- A claimed invitation is reopened only if it is still in the accepted state
  and belongs to the registration's recorded proof. If its expiry has passed,
  its state becomes `expired`, not `pending`. A revoked invitation stays
  revoked. No transition may make an expired or revoked invitation usable.
- Reopened invitations retain the claimant binding. Authorization and claim
  must reject a different user when `invited_user_id` is already bound, while
  allowing that same user to retry. For guest OTP, compare the normalized
  submitted phone to the bound user's phone before creating/resolving a shadow
  identity or sending a challenge.
- Keep proof foreign keys on the registration as historical evidence. Audit
  only proof type, record ID, quantity, transition reason, and registration ID;
  never log raw access codes or invitation tokens.
- Reacquisition is also written to the audit log in the same transaction as
  reconsideration, with the same non-secret metadata boundaries.
- A failure to restore proof or write its audit record aborts the entire
  terminal transition or reacquisition. Exact replays must not return or
  reacquire proof a second time.

## Reconsideration

An organizer may reconsider a rejected registration. If the decision is to
approve, the registration must reacquire its previously associated proof before
the status can leave `rejected`:

- Reacquire an access-code use for the original package quantity, validating
  its current active window, per-use limit, and remaining uses.
- Reclaim the associated invitation only if it is pending, unexpired, within
  its quantity allowance, and still bound to the same claimant.
- Resolve proof through the stored association IDs; do not decrypt or log raw
  code/token values for this operation.
- If proof is no longer valid or available, fail the reconsideration and leave
  the registration rejected. A successful reacquisition and approval are one
  transaction.

Reconsidering a rejection as another rejection does not restore proof again.
Reconsideration of an expired or buyer-cancelled registration is out of scope.

## Checkout eligibility

New ticket checkout quotes and checkout creation may use only a registration
in `pending_payment`. A registration made `expired`, `cancelled`, `rejected`,
`confirmed`, or otherwise non-payable cannot be attached to a new order. This
prevents an old quote or direct checkout request from bypassing proof
restoration. An idempotent replay of an already-created order remains a replay
of that order and does not create a new order.

Restarting an active checkout before final expiry reuses the same pending
registration; it does not release or reacquire proof. The order-item uniqueness
boundary is one row per `(registration_id, order_id)`, retaining each closed
order's immutable evidence while allowing the replacement order to reference
that registration. Existing buyer/event advisory locking and active-checkout
checks ensure only one active order can use the registration at a time. A
closed order's later payment success remains subject to the existing late-payment
reversal path.

## Architecture and transaction boundaries

Use an explicit Ticketing lifecycle command for releasing/reacquiring audience
proof; do not add model callbacks. Invoke it inside the existing transactions
for `Ticketing::Registrations::ReleasePending`,
`Ticketing::RegistrationDecisions::Reject`, `Orders::ReleaseCheckout`, and
`Ticketing::RegistrationDecisions::Reconsider`. The order expiry command must
lock and transition each linked registration once, in deterministic order.
`Orders::ReleaseCheckout` expires registrations only for the
`checkout_expired` reason; `buyer_requested` checkout closure is followed by
`ReleasePending` changing the registration to `cancelled` and returning proof.
Buyer release and final checkout expiry must serialize on the existing
`orders-checkout` advisory key `(buyer_id, event_id)` before taking row locks;
then lock order/payment rows before registration/proof rows. This matches the
existing payment-acceptance order/payment/registration lock sequence and avoids
a buyer release holding a registration while waiting on a payment-acceptance
order lock. Reconsideration and organizer rejection have no order and lock the
registration before its proof row. Preserve the module dependency direction:
Orders may call Ticketing; Ticketing must not call Orders from the shared proof
lifecycle command.

The registration status transition is the exactly-once boundary: current
release commands already lock and guard their allowed source statuses. No
separate proof ledger/table is required for this scope. Update the original
`orders_order_items` migration and `db/structure.sql` so the unique index is
`(registration_id, order_id)` for non-null registrations; do not add a new
migration or alter other order-item identity invariants. If a terminal
transition is replayed, its existing status/idempotency handling returns
without a second compensation. If reconsideration successfully reacquires
proof, a later rejection is a new valid transition and returns that newly
consumed proof once.

## Out of scope

- Restoring proof on event-wide cancellation, waitlist expiry, transfer, resale,
  or any other lifecycle not listed above.
- Returning proof while payment is still in the active settlement-grace path.
- New public API routes or request/response fields.
- Changing invitation/contact matching or access-code allocation policy beyond
  the claimant-binding rule above.
- New tables/columns or database invariants beyond the approved composite
  order-item index change.

## Acceptance criteria

1. Buyer release, organizer rejection, and final checkout expiry restore the
   correct proof exactly once and atomically with the state transition.
2. Access-code usage is restored by package quantity without underflow; a
   counter inconsistency leaves both proof and registration/order unchanged.
3. Invitations reopen only when still valid and not revoked; expired ones stay
   unusable, and an invitation bound to one claimant cannot be claimed by
   another after reopening.
4. Final checkout expiry invalidates linked pending registrations; new quotes
   and checkouts reject those registrations. Active checkout restart keeps the
   registration/proof unchanged and permits one order item per
   `(registration_id, order_id)` without allowing two active orders to share
   that registration.
5. Reconsideration approval revalidates and reacquires proof atomically; an
   unavailable or expired proof leaves the registration rejected.
6. Replays and concurrent terminal transitions cannot restore the same proof
   twice; failures in audit, proof handling, or persistence roll back the full
   transition.
7. Tests cover the three release paths, proof-specific edge cases, exact
   replay/concurrency, reconsideration, and checkout reuse rejection. Existing
   RSVP, registration, checkout, and payment-expiry behavior remains green.
