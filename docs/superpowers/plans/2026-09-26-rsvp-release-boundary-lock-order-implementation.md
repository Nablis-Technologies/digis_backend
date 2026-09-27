# RSVP Release Boundary and Checkout Locking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers-ruby:executing-plans` to implement this plan task-by-task. Keep every change unstaged and uncommitted for the user to review.

**Goal:** Remove the Ticketing-to-Orders dependency from buyer registration release and make every checkout release path acquire the shared advisory lock before conflicting row locks.

**Architecture:** `Orders::ReleaseBuyerRegistration` owns the cross-domain checkout transaction and calls the Ticketing-only registration/proof transition after it has serialized and released any active checkout. The existing `POST /registrations/:id/release` contract remains unchanged, but its handler moves to Orders. `Orders::ReleaseCheckout` becomes self-locking, and every known checkout/resale caller follows the same lock protocol.

**Tech Stack:** Rails 8.1, Active Record, PostgreSQL transaction advisory locks, Minitest, RuboCop.

**Spec:** `docs/superpowers/specs/2026-09-26-rsvp-release-boundaries-and-checkout-locks-design.md`

## Global Constraints

- Orders may depend on Ticketing; the buyer-release flow must not add a Ticketing-to-Orders reference.
- Preserve `POST /registrations/:id/release`, its authorization, required `Idempotency-Key`, response, and serializer.
- Acquire `orders-checkout(buyer_id, event_id)` before order/payment/registration locks and before marketplace listing locks that serialize that checkout.
- Resale reservation and policy disablement lock the ticket type before the checkout key, then acquire the key before listing/order locks; policy disablement never pre-locks listings before calling `CancelListing`.
- Acquire the checkout key before Event-backed order/payment locks: checkout creation uses key → Event → Order, and payment-attempt/acceptance flows use key → Order → Event → Payment.
- Preserve the existing G-27/G-29/G-34 behavior, including proof restoration/reacquisition, active-checkout restart, and `(registration_id, order_id)` uniqueness.
- Do not add migrations, tables, columns, model callbacks, or backwards-compatibility layers.
- Add concise class comments to the new public service/controller/helper and explain the non-obvious advisory-lock ordering at the lock boundary.
- Execute in the current checkout because the prior G-27/G-29/G-34 implementation and other user changes are uncommitted dependencies. Edit only scoped files; preserve all unrelated changes.
- Do not stage, commit, deploy, or modify a remote database. Local tests use only `digis_backend_test`.

## Review Focus

- A buyer release racing payment acceptance must never hold the registration while waiting for an order/payment row; assert advisory → order → blocking payment → registration ordering.
- A direct `Orders::ReleaseCheckout` invocation must acquire the advisory lock before its own order lock.
- Payment-attempt creation, provider-result persistence, webhook event application, and payment acceptance must acquire the checkout key before event-payment row mutations/locks; the PaymentEvent inbox lock is allowed first.
- Marketplace cancellation/expiry/reservation and checkout creation must not acquire a conflicting row lock and then wait for the checkout advisory lock.
- A buyer who does not own a registration must not lock or release that registration's orders.
- Replays, proof/audit failures, and paid or payment-in-progress attempts must retain their current results and atomic rollback behavior.

---

### Task 1: Move buyer-release orchestration into Orders

**Files:**
- Modify: `app/models/orders/payment.rb`
- Create: `app/services/orders/release_buyer_registration.rb`
- Create: `app/controllers/orders/registration_checkouts_controller.rb`
- Modify: `app/services/ticketing/registrations/release_pending.rb`
- Modify: `app/controllers/ticketing/registrations_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/services/orders/release_buyer_registration_test.rb`
- Modify: `test/services/ticketing/registrations/release_pending_test.rb`
- Modify: `test/integration/ticketing/registrations_test.rb`

**Interfaces:**
- Produce `Orders::ReleaseBuyerRegistration.call(registration_id:, buyer:, idempotency_key:, at: Time.current)` returning the existing `Core::BaseService::Result` contract.
- Move the existing blocking set `%w[created processing succeeded unknown timeout]` to `Orders::Payment::RELEASE_BLOCKING_STATUSES`; do not leave payment status knowledge in Ticketing.
- Preserve `registration_not_owned` as `403/forbidden`, missing registration as `registration_not_releasable`/`404`, and release/payment errors as the existing localized conflict results.
- Implement `release_error(code, status:)` to return a `Core::BusinessError` using `I18n.t("ticketing.registration_workflows.errors.#{code}")` and the same code/status tuple used by `Ticketing::Registrations::ReleasePending` today.
- Keep `Ticketing::Registrations::ReleasePending.call(registration:, buyer:, idempotency_key:, at:)` as a Ticketing-only leaf: lock and revalidate the registration, cancel it, release its stored proof, and write the existing audits. It must not reference `Orders::*` or acquire the Orders checkout lock.
- Map `POST /registrations/:id/release` to `Orders::RegistrationCheckoutsController#create`; keep registration `show` and `create` on `Ticketing::RegistrationsController`.

- [x] **Step 1: Add failing Orders command and HTTP contract tests**

Add service tests for: a buyer-owned registration without an order; one active checkout released before registration cancellation; rejection when any linked order is paid; rejection when a payment has a blocking status; wrong buyer returns forbidden without taking checkout row locks; exactly one Order row-lock query when closing an active checkout; proof/audit failure rolls back order and registration state; and cancelled-registration replay succeeds before checking terminal payment statuses. Extend the integration release test to prove the existing URL, required header, authorization, status/body, serializer, and replay remain unchanged after route ownership moves.

Pin route ownership without changing the path:

```ruby
assert_recognizes(
  { controller: "orders/registration_checkouts", action: "create", id: registration.id },
  { path: "/registrations/#{registration.id}/release", method: :post }
)
```

Pin successful orchestration against the existing test graph:

```ruby
result = Orders::ReleaseBuyerRegistration.call(
  registration_id: registration.id,
  buyer: registration.user,
  idempotency_key: "registration-release-#{SecureRandom.hex(4)}"
)

assert_predicate result, :success?, result.error&.message
assert_equal "cancelled", registration.reload.status
assert_equal "expired", order.reload.status if order
```

Run the focused new/modified tests with the asdf Ruby 3.4.2 and Bundler 2.7.1 available in this environment:

```bash
PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH bundle exec rails test \
  test/services/orders/release_buyer_registration_test.rb \
  test/services/ticketing/registrations/release_pending_test.rb \
  test/integration/ticketing/registrations_test.rb
```

Expected: the new Orders service is missing and the route still targets the Ticketing controller; tests fail for those expected contract gaps.

- [x] **Step 2: Implement the Orders-owned transaction boundary**

In `Orders::ReleaseBuyerRegistration`, read the registration's buyer/event identity without row locks; reject a mismatched buyer before acquiring locks; acquire the checkout advisory key; lock every linked order in ID order and only payment rows in the statuses that currently block release; then lock/revalidate the registration. Preserve the existing paid-order and payment-in-progress typed errors. Close the eligible active checkout with `reason: "buyer_requested"`, then invoke the Ticketing leaf transition in the same transaction. Raise on either command's failure so the outer transaction rolls back. Move only the release action to the Orders controller and preserve the public path and serializer. Remove order/payment lookups, status constants, checkout calls, and advisory-lock ownership from `Ticketing::Registrations::ReleasePending`.

The Orders command's locked section follows this exact sequence (error/result
mapping remains in the named service methods):

```ruby
identity = Ticketing::Registration.where(id: registration_id).pick(:user_id, :event_id)
return failure(release_error(:registration_not_releasable, status: :not_found)) unless identity
return failure(release_error(:registration_not_owned, status: :forbidden)) unless identity.first == buyer.id

Core::Database::AdvisoryLock.acquire!("orders-checkout", buyer.id, identity.last)
orders = lock_linked_orders(registration_id)
payments = lock_blocking_payments(orders)
registration = Ticketing::Registration.lock.find(registration_id)
validate_buyer_and_release_state!(registration, buyer)
return success(registration) if registration.cancelled?
reject_paid_or_inflight!(orders, payments)
release_active_checkout!(orders, at:) # delegates to ReleaseCheckout.call_locked
release_registration_proof!(registration, buyer, idempotency_key, at:)
```

- [x] **Step 3: Re-run Task 1 tests and inspect the module boundary**

Run the Step 1 command. Expected: all tests pass. Also run `rg -n 'Orders::|orders_' app/services/ticketing/registrations/release_pending.rb`; expected: no matches. Confirm `config/routes.rb` still exposes exactly `POST /registrations/:id/release` and that no Postman request path/body change is needed.

### Task 2: Centralize checkout lock acquisition and normalize callers

**Files:**
- Create: `app/services/orders/checkout_lock.rb`
- Modify: `app/services/orders/release_checkout.rb`
- Modify: `app/services/orders/release_buyer_registration.rb`
- Modify: `app/services/orders/create_checkout.rb`
- Modify: `app/services/orders/expire_checkout.rb`
- Modify: `app/services/orders/expire_settlement_grace.rb`
- Modify: `app/services/orders/restart_checkout.rb`
- Modify: `app/services/orders/start_payment_attempt.rb`
- Modify: `app/services/orders/accept_payment.rb`
- Modify: `app/services/orders/process_payment_event.rb`
- Modify: `app/services/orders/fulfill_order.rb`
- Modify: `app/services/marketplace/reserve_listing.rb`
- Modify: `app/services/marketplace/cancel_listing.rb`
- Modify: `app/services/marketplace/expire_reservation.rb`
- Modify: `app/services/marketplace/fulfill_sale.rb`
- Modify: `app/services/marketplace/configure_ticket_type_resale.rb`
- Test: `test/services/orders/release_checkout_test.rb`
- Modify: `test/services/orders/create_checkout_test.rb`
- Modify: `test/services/orders/expire_checkout_test.rb`
- Modify: `test/services/orders/expire_settlement_grace_test.rb`
- Modify: `test/services/orders/restart_checkout_test.rb`
- Modify: `test/services/orders/start_payment_attempt_test.rb`
- Modify: `test/services/orders/process_payment_event_test.rb`
- Modify: `test/services/marketplace/fulfill_sale_test.rb`
- Modify: `test/integration/marketplace/resale_late_payment_test.rb`
- Modify: `test/services/marketplace/reserve_listing_test.rb`
- Create: `test/services/marketplace/cancel_listing_test.rb`
- Modify: `test/services/marketplace/expire_reservation_test.rb`
- Modify: `test/integration/marketplace/concurrent_listing_test.rb`

**Interfaces:**
- Produce `Orders::CheckoutLock.acquire!(buyer_user_id:, event_id:)`, delegating to `Core::Database::AdvisoryLock.acquire!("orders-checkout", buyer_user_id, event_id)`.
- Produce `Orders::CheckoutLock.acquire_all!(buyer_event_pairs)`, where the input is an array of `[buyer_user_id, event_id]` pairs, sorted deterministically and passed to `Core::Database::AdvisoryLock.acquire_all!` in one call.
- Produce `Orders::CheckoutLock.acquire_for_order!(order_id:, ticket_type_ids: nil)`. For resale orders it locks linked Ticketing ticket types in deterministic order before acquiring the buyer/event checkout key; direct fulfillment may supply the listing's ticket-type ID. This prevents the Type→key expiry/cancel order from deadlocking against payment success.
- `Orders::ReleaseCheckout` derives the immutable buyer/event key with a read-only lookup, starts/joins the transaction, acquires that key, and only then locks the order.
- `Orders::ReleaseCheckout.call_locked(order:, reason:, at:)` is for callers already holding the checkout key and order/payment rows. It requires an open transaction, avoids duplicate Order/Payment locks, and uses a savepoint for release mutations.
- `Marketplace::ReserveListing` locks `Ticketing::TicketType`, acquires `Orders::CheckoutLock`, then locks the listing/order. `ConfigureTicketTypeResale` holds the ticket-type lock, enumerates reservation identities without row locks, atomically acquires all corresponding checkout keys, then delegates each listing transition. Direct cancel/expiry lock ticket type before checkout key and listing.
- `StartPaymentAttempt` acquires the key before Order/Event/Payment locks both when reserving an attempt and persisting provider results. For resale, `AcceptPayment`, settlement-grace reconciliation, and `ProcessPaymentEvent` acquire TicketType→checkout-key→Order/Event/Payment. `FulfillOrder` and direct `FulfillSale` use the same TicketType→key order before listing locks. Non-resale payment acceptance remains checkout-key-first. `ProcessPaymentEvent` may lock its `PaymentEvent` inbox row first, but acquires the appropriate resale/type/key sequence before any event-payment row write; billing payments skip this event-checkout lock.
- Every caller that acquires a checkout-conflicting row before calling `ReleaseCheckout` must acquire the shared key before that row. Event-payment transactions follow the key-first order specified above.

- [x] **Step 1: Add failing lock-order regressions**

Add a `sql.active_record` notification test to `Orders::ReleaseCheckoutTest` that invokes the command directly and asserts the advisory-lock query precedes the first `orders_orders ... FOR UPDATE` query. Add/extend command tests to assert advisory → orders → blocking payments → registration for buyer release and that its candidate order is locked exactly once; advisory → Order → Event → Payment for StartPaymentAttempt and non-resale AcceptPayment; PaymentEvent → applicable checkout lock(s) → event-Payment write for ProcessPaymentEvent; and TicketType → advisory → Order for resale acceptance. Assert checkout creation key → Event → Order. Add tests for ticket-type → advisory → listing/order in Marketplace reserve, policy disablement, and direct FulfillSale, plus advisory-before-listing/order for cancellation and reservation expiry. Retain the concurrent expiry/fulfillment regression. Use real database rows and unsubscribe every notification subscriber in `ensure`.

The direct-command assertion should compare captured SQL indexes:

```ruby
advisory = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
order_lock = statements.index { |sql| sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i) }

assert_not_nil advisory
assert_not_nil order_lock
assert_operator advisory, :<, order_lock
```

Run:

```bash
PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH bundle exec rails test \
  test/services/orders/release_checkout_test.rb \
  test/services/orders/create_checkout_test.rb \
  test/services/orders/start_payment_attempt_test.rb \
  test/services/orders/process_payment_event_test.rb \
  test/services/marketplace/reserve_listing_test.rb \
  test/services/marketplace/cancel_listing_test.rb \
  test/services/marketplace/expire_reservation_test.rb \
  test/services/marketplace/configure_ticket_type_resale_test.rb \
  test/integration/marketplace/concurrent_listing_test.rb
```

Expected: direct `ReleaseCheckout`, StartPaymentAttempt, ProcessPaymentEvent, Marketplace reserve/cancel/expiry, and policy-disable tests expose their existing missing/late acquisitions; checkout creation's event→advisory test fails and demonstrates the cycle.

- [x] **Step 2: Implement the shared lock boundary and reorder callers**

Add `Orders::CheckoutLock.acquire_all!`, sorting buyer/event keys and delegating to the Core multi-key advisory lock. Use it at the start of buyer-release orchestration and inside direct `Orders::ReleaseCheckout.call`, before its order row lock. Let callers already holding the checkout key and order/payment rows invoke `Orders::ReleaseCheckout.call_locked`; this path must not repeat those row locks and must roll back its release work with a savepoint on failure. Replace direct key construction in Orders expiry/restart commands with the helper. In `Orders::CreateCheckout`, acquire the key before its Event lock and before replay/active-order locks. In `StartPaymentAttempt`, acquire the key before Order/Event/Payment locks when reserving an attempt and before Order/Payment locks when persisting a provider result; both transactions must acquire the key independently. In `AcceptPayment`, acquire resale TicketType rows before the shared key, then take Order/Event/Payment locks; normal event payments remain key-first. In `ProcessPaymentEvent`, after locking/locating its inbox row/payment, acquire the same order-specific lock sequence before recording provider references or mutating an event-payment status; nested `AcceptPayment` acquisition is reentrant, and billing payments skip the event-checkout lock. `ExpireSettlementGrace` must acquire that sequence before Order/Payment locks. `FulfillOrder` and direct `FulfillSale` must be safe when called directly, so resale Type→key precedes Order/listing locks. In `Marketplace::ReserveListing`, lock the listing's ticket type, acquire the key, then lock the listing and idempotent-order rows. In `Marketplace::CancelListing` and `Marketplace::ExpireReservation`, lock ticket type before the key, preflight the reserved order identity without row locks, then lock/revalidate listing and order; fail closed if the reserved order changed after preflight. In `ConfigureTicketTypeResale`, retain the ticket-type lock, enumerate listing IDs and reserved-order identities without row locks, acquire the corresponding checkout keys in sorted order, then delegate each cancellation to `CancelListing`. Ensure no caller reaches `ReleaseCheckout` while holding an order/payment lock obtained before the key.

Use one key builder for all these paths:

```ruby
module Orders
  class CheckoutLock
    def self.acquire!(buyer_user_id:, event_id:)
      Core::Database::AdvisoryLock.acquire!("orders-checkout", buyer_user_id, event_id)
    end

    def self.acquire_all!(buyer_event_pairs)
      lock_parts = buyer_event_pairs.map { |buyer_id, event_id| [ "orders-checkout", buyer_id, event_id ] }
        .uniq
        .sort_by { |parts| parts.map(&:to_s).join(":") }
      Core::Database::AdvisoryLock.acquire_all!(*lock_parts)
    end
  end
end
```

- [x] **Step 3: Run focused lock-order, resale, and expiry tests**

Run the Step 1 command plus `test/services/orders/expire_checkout_test.rb`, `test/services/orders/expire_settlement_grace_test.rb`, `test/services/orders/restart_checkout_test.rb`, `test/integration/orders/concurrent_checkout_test.rb`, `test/integration/marketplace/concurrent_purchase_test.rb`, `test/integration/marketplace/concurrent_resale_success_test.rb`, and `test/integration/marketplace/resale_late_payment_test.rb`. Expected: all prior reservation/cancellation/expiry behavior remains green; direct and caller-level SQL assertions show the agreed order; resale-policy disablement serializes safely; duplicate expiry/cancellation still resolves exactly once.

### Task 3: Consolidate proof support and make lookup-mode validation explicit

**Files:**
- Create: `app/services/ticketing/registrations/audience_proof/support.rb`
- Modify: `app/services/ticketing/registrations/audience_proof/release.rb`
- Modify: `app/services/ticketing/registrations/audience_proof/reacquire.rb`
- Modify: `app/services/ticketing/access_codes/consume.rb`
- Modify: `app/services/ticketing/invitations/claim.rb`
- Modify: `test/services/ticketing/registrations/audience_proof/release_test.rb`
- Modify: `test/services/ticketing/registrations/audience_proof/reacquire_test.rb`
- Modify: `test/services/ticketing/access_codes/consume_test.rb`
- Modify: `test/services/ticketing/invitations/claim_test.rb`

**Interfaces:**
- `AudienceProof::Support.proof_reference(registration:)` returns `[kind, record]`, where `kind` is `:access_code`, `:invitation`, `:public`, `:missing`, or `:inconsistent`; Release/Reacquire map `:missing` and `:inconsistent` to their current distinct errors.
- `AudienceProof::Support.transition_digest(value)` returns `Core::IdempotencyKey.new(value).digest` or `nil` for the same constructor errors currently handled by both commands.
- Lookup-mode predicates accept exactly one valid mode: raw string or persisted associated record. Both-present, neither-present, wrong-class, and unsaved records fail closed.
- Use `Ticketing::Registrations::Support::Halt` for result-carrying rollback if its current contract remains suitable; do not retain duplicate private `Abort` wrappers.

- [x] **Step 1: Add failing edge tests for lookup modes and shared transitions**

Add cases to `ConsumeTest` and `ClaimTest` for raw-only success, persisted-record-only success, both modes rejected, no mode rejected, and a wrong-class record whose `id` matches an existing proof record rejected. Preserve expiry, quantity, claimant, and audit-failure tests for proof release/reacquisition. The wrong-class/matching-ID case is the expected RED assertion; other cases pin already-correct behavior through the refactor.

For each command, the explicit predicate must retain record type/persistence checks:

```ruby
def valid_lookup_mode?
  raw_lookup = @raw_code.is_a?(String) && @raw_code.present?
  record_lookup = @access_code.present?
  return false if raw_lookup == record_lookup
  return raw_lookup unless record_lookup

  @access_code.is_a?(Ticketing::AccessCode) && @access_code.persisted?
end
```

Implement the mirrored `Invitations::Claim#valid_lookup_mode?` using
`@raw_token` and a persisted `Ticketing::Invitation` record. The test passes a
small object with the ID of an existing proof row, not the proof model, so the
current ID-only lookup fails before production code changes.

Run:

```bash
PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH bundle exec rails test \
  test/services/ticketing/access_codes/consume_test.rb \
  test/services/ticketing/invitations/claim_test.rb \
  test/services/ticketing/registrations/audience_proof/release_test.rb \
  test/services/ticketing/registrations/audience_proof/reacquire_test.rb
```

Expected: the new wrong-class/matching-ID case fails because the current service trusts any object's `id` and reloads that proof row; all existing tests remain loadable.

- [x] **Step 2: Implement shared proof support and explicit lookup guards**

Extract only the identical association resolution and transition digest parsing needed by `Release`/`Reacquire`; keep their different business-error codes and state changes local. Replace duplicated `Abort` classes with the existing result-carrying `Support::Halt`. Store the associated record itself, then use a named predicate that checks raw-string presence and associated-record class/persistence, not ID XOR alone. Keep underflow and invitation state updates inside `AudienceProof::Release`; do not add model methods solely to wrap `update!`.

- [x] **Step 3: Run focused proof tests and confirm green**

Run the Step 1 command. Expected: all edge cases pass, proof release/reacquisition audit behavior and rollback remain unchanged, and no raw proof reaches audit/log output.

### Task 4: Cross-flow verification and handoff

**Files:**
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`
- Verify: `postman/Digis API_collection.json`
- Verify: the approved spec and all Tasks 1–3 interfaces.

- [x] **Step 1: Run the complete affected suite normally and with N+1 detection**

Run:

```bash
PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH bundle exec rails test \
  test/services/ticketing/registrations/audience_proof/release_test.rb \
  test/services/ticketing/registrations/audience_proof/reacquire_test.rb \
  test/services/ticketing/access_codes/consume_test.rb \
  test/services/ticketing/invitations/claim_test.rb \
  test/services/ticketing/audience/authorize_test.rb \
  test/integration/ticketing/public_rsvps_test.rb \
  test/services/ticketing/registrations/release_pending_test.rb \
  test/services/ticketing/registration_decisions/reject_test.rb \
  test/services/ticketing/registration_decisions/approve_test.rb \
  test/services/orders/release_buyer_registration_test.rb \
  test/services/orders/release_checkout_test.rb \
  test/services/orders/create_checkout_test.rb \
  test/services/orders/expire_checkout_test.rb \
  test/services/orders/expire_settlement_grace_test.rb \
  test/services/orders/restart_checkout_test.rb \
  test/services/orders/start_payment_attempt_test.rb \
  test/services/orders/process_payment_event_test.rb \
  test/integration/orders/concurrent_checkout_test.rb \
  test/integration/ticketing/registrations_test.rb \
  test/integration/orders/guest_checkout_test.rb \
  test/services/marketplace/reserve_listing_test.rb \
  test/services/marketplace/cancel_listing_test.rb \
  test/services/marketplace/expire_reservation_test.rb \
  test/services/marketplace/configure_ticket_type_resale_test.rb \
  test/integration/marketplace/concurrent_listing_test.rb \
  test/integration/marketplace/concurrent_purchase_test.rb \
  test/integration/marketplace/concurrent_resale_success_test.rb \
  test/integration/marketplace/resale_late_payment_test.rb
```

Run the same command prefixed with `N_PLUS_ONE=1`. Expected: zero failures, errors, or skips in both runs.

- [x] **Step 2: Run quality and artifact checks**

Run:

```bash
PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH bundle exec rubocop --cache false \
  app/models/orders/payment.rb \
  app/services/orders/checkout_lock.rb \
  app/services/orders/release_buyer_registration.rb \
  app/services/orders/release_checkout.rb \
  app/services/orders/create_checkout.rb \
  app/services/orders/expire_checkout.rb \
  app/services/orders/expire_settlement_grace.rb \
  app/services/orders/restart_checkout.rb \
  app/services/orders/start_payment_attempt.rb \
  app/services/orders/accept_payment.rb \
  app/services/orders/process_payment_event.rb \
  app/services/orders/fulfill_order.rb \
  app/services/marketplace/reserve_listing.rb \
  app/services/marketplace/cancel_listing.rb \
  app/services/marketplace/expire_reservation.rb \
  app/services/marketplace/fulfill_sale.rb \
  app/services/marketplace/configure_ticket_type_resale.rb \
  app/services/ticketing/registrations/release_pending.rb \
  app/services/ticketing/registrations/audience_proof/support.rb \
  app/services/ticketing/registrations/audience_proof/release.rb \
  app/services/ticketing/registrations/audience_proof/reacquire.rb \
  app/services/ticketing/access_codes/consume.rb \
  app/services/ticketing/invitations/claim.rb \
  app/controllers/orders/registration_checkouts_controller.rb \
  app/controllers/ticketing/registrations_controller.rb \
  test/services/orders/release_buyer_registration_test.rb \
  test/services/orders/release_checkout_test.rb \
  test/services/orders/create_checkout_test.rb \
  test/services/orders/expire_checkout_test.rb \
  test/services/orders/expire_settlement_grace_test.rb \
  test/services/orders/restart_checkout_test.rb \
  test/services/orders/start_payment_attempt_test.rb \
  test/services/orders/process_payment_event_test.rb \
  test/services/marketplace/fulfill_sale_test.rb \
  test/services/marketplace/reserve_listing_test.rb \
  test/services/marketplace/cancel_listing_test.rb \
  test/services/marketplace/expire_reservation_test.rb \
  test/services/marketplace/configure_ticket_type_resale_test.rb \
  test/services/ticketing/registrations/release_pending_test.rb \
  test/services/ticketing/access_codes/consume_test.rb \
  test/services/ticketing/invitations/claim_test.rb \
  test/services/ticketing/registrations/audience_proof/release_test.rb \
  test/services/ticketing/registrations/audience_proof/reacquire_test.rb \
  test/integration/ticketing/registrations_test.rb \
  test/integration/orders/concurrent_checkout_test.rb \
  test/integration/marketplace/concurrent_listing_test.rb \
  test/integration/marketplace/resale_late_payment_test.rb

PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH bundle exec rails zeitwerk:check
git diff --check
PATH=/Users/adoniyas/.asdf/shims:/Users/adoniyas/.asdf/bin:$PATH ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "Postman collection JSON valid"'
```

Expected: no RuboCop offenses, Zeitwerk “All is good!”, a clean diff check, and valid Postman JSON. Confirm the API request contract and route remain unchanged.

- [x] **Step 3: Review the exact diff and record status**

Self-review the service dependency graph and actual SQL lock order against the approved spec. Update G-27/G-29/G-34 tracker counts and explicitly leave Render preview verification pending. Confirm no files were staged or committed and unrelated existing changes remain untouched. Do not deploy or reset any database other than the local test database.
