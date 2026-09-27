# RSVP Audience Proof Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox syntax for tracking. Do not stage or commit; the user reviews and commits manually.

**Goal:** Restore access-code uses and invitation claims exactly once when an RSVP registration is released, rejected, or finally expires, without leaving a payable registration that can bypass its proof.

**Architecture:** Add explicit Ticketing release/reacquisition commands and call them from the existing locked lifecycle transactions. Checkout expiry terminalizes linked pending registrations and restores proof; reconsideration revalidates and reacquires proof before approval. Preserve closed order-item evidence while supporting sequential ticket checkout restarts through the approved composite registration/order index; avoid callbacks and public API changes, and serialize buyer-release/checkout-expiry paths on the existing checkout advisory lock.

**Tech Stack:** Ruby 3.4, Rails 8.1, ActiveRecord/PostgreSQL, Minitest, RuboCop.

**Spec:** `docs/superpowers/specs/2026-09-26-rsvp-audience-proof-release-design.md`

## Global Constraints

- Access-code use is returned/reacquired by `registration.package_quantity` under a row lock.
- Registration, proof, audit, and order state changes commit or roll back together.
- No raw access code or invitation token may enter logs or audit metadata.
- Do not add model callbacks.
- Orders may depend on Ticketing; Ticketing must not call Orders from the shared proof lifecycle command.
- Edit the original order-item migration and `db/structure.sql` only for the approved `(registration_id, order_id)` unique index change where registration is non-null; do not add a new migration, table, column, or other schema change.
- Buyer release and final checkout expiry acquire the existing `orders-checkout` advisory key `(buyer_id, event_id)` before row locks.
- Do not stage or commit; preserve unrelated working-tree changes.

## Review Focus

- A checkout with an active settlement-grace attempt must keep its proof consumed; the initial checkout deadline alone is not final expiry. Pin in Task 3's `ExpireCheckoutTest` and `ExpireSettlementGraceTest`.
- Counter underflow or restoration failure must leave the registration/order and proof unchanged. Pin in Task 1's `AudienceProof::ReleaseTest` and Task 2 transition tests.
- An expired/revoked invitation or a bound invitation presented by another phone/user must never become usable or receive a guest OTP. Pin in Task 1's invitation and public-RSVP tests.
- Reconsideration must remain rejected when a code is exhausted or the invitation is unavailable/expired. Pin in Task 2's `RegistrationDecisions::ApproveTest`.
- A stale quote cannot create a new order for an expired registration, while exact replay of an existing order remains a replay. Pin in Task 3's `BuildQuoteTest` and `CreateCheckoutTest`.

---

### Task 1: Add proof release/reacquisition primitives and claimant binding

**Files:**
- Create: `app/services/ticketing/registrations/audience_proof/release.rb`
- Create: `app/services/ticketing/registrations/audience_proof/reacquire.rb`
- Test: `test/services/ticketing/registrations/audience_proof/release_test.rb`
- Test: `test/services/ticketing/registrations/audience_proof/reacquire_test.rb`
- Modify: `app/services/ticketing/access_codes/consume.rb`
- Modify: `app/services/ticketing/invitations/claim.rb`
- Modify: `app/services/ticketing/audience/authorize.rb`
- Modify: `app/services/ticketing/rsvps/request_otp.rb`
- Modify: `config/locales/ticketing/registration_workflows.en.yml`
- Modify: `config/locales/ticketing/invitation.en.yml`
- Test: `test/services/ticketing/access_codes/consume_test.rb`
- Test: `test/services/ticketing/invitations/claim_test.rb`
- Test: `test/services/ticketing/audience/authorize_test.rb`
- Test: `test/integration/ticketing/public_rsvps_test.rb`

**Interfaces:**
- Produces `Ticketing::Registrations::AudienceProof::Release.call(registration:, reason:, transition_key:, at: Time.current)`, returning a service result; the caller supplies a non-secret transition key and owns the terminal status transaction.
- Produces `Ticketing::Registrations::AudienceProof::Reacquire.call(registration:, transition_key:, at: Time.current)`, returning a service result and operating only through the registration's stored proof association.
- Existing `Ticketing::AccessCodes::Consume` and `Ticketing::Invitations::Claim` continue to accept raw proof for new submissions and additionally accept the stored associated record for safe reacquisition; exactly one lookup mode is allowed per call.
- `Ticketing::Audience::Authorize` accepts optional `user:` and `phone:` identity evidence for invitation claimant binding.

- [x] **Step 1: Write failing release/reacquire tests**

Add tests proving: package quantity is returned from `used_count`; underflow and release-audit failure leave state unchanged; a still-valid accepted invitation returns to pending; expired invitations become/remain expired; revoked invitations stay revoked; release and reacquisition audit metadata exclude raw secrets; reacquisition audit failure rolls the proof mutation back; reacquisition validates code windows/limits and invitation expiry/allowance/claimant; and reacquisition uses association IDs without decrypting raw proof.

- [x] **Step 2: Run the focused service tests and confirm they fail for the missing lifecycle commands/behavior**

Run: `bundle exec rails test test/services/ticketing/registrations/audience_proof/release_test.rb test/services/ticketing/registrations/audience_proof/reacquire_test.rb test/services/ticketing/access_codes/consume_test.rb test/services/ticketing/invitations/claim_test.rb`

Expected: the new lifecycle tests fail because release/reacquisition commands and associated-record lookup are not implemented; existing tests remain loadable.

- [x] **Step 3: Implement the two explicit Ticketing lifecycle commands**

Lock the registration's associated proof row, change only the permitted status/counter fields, write a unique audit record containing IDs/type/quantity/reason only, and return typed failures for inconsistent counters or unavailable proof. Both commands accept the parent's non-secret transition key; keep all work inside the caller's transaction.

- [x] **Step 4: Enforce invitation claimant binding on authorization, OTP, and claim**

Keep OTP proof checks read-only: compare a bound invitation's normalized user phone to the submitted phone before shadow-identity creation or challenge delivery. At submission/claim time, require the same `Core::User` when `invited_user_id` is already set.

- [x] **Step 5: Run focused tests and confirm green**

Run: `bundle exec rails test test/services/ticketing/registrations/audience_proof/release_test.rb test/services/ticketing/registrations/audience_proof/reacquire_test.rb test/services/ticketing/access_codes/consume_test.rb test/services/ticketing/invitations/claim_test.rb test/services/ticketing/audience/authorize_test.rb test/integration/ticketing/public_rsvps_test.rb`

Expected: all focused tests pass; guest OTP with a mismatched bound phone creates no challenge/shadow user; same-claimant retry succeeds.

### Task 2: Compensate buyer release/rejection and reacquire on reconsideration

**Files:**
- Modify: `app/services/ticketing/registrations/release_pending.rb`
- Modify: `app/services/ticketing/registration_decisions/reject.rb`
- Modify: `app/services/ticketing/registration_decisions/reconsider.rb`
- Test: `test/services/ticketing/registrations/release_pending_test.rb`
- Create: `test/services/ticketing/registration_decisions/reject_test.rb`
- Modify: `test/services/ticketing/registration_decisions/approve_test.rb`

**Interfaces:**
- Consumes `AudienceProof::Release.call(registration:, reason:, transition_key:, at:)` and `AudienceProof::Reacquire.call(registration:, transition_key:, at:)` from Task 1.
- `ReleasePending` obtains the shared checkout advisory lock, then locks related orders and payment rows in statuses that block release before the registration; `Reject` releases proof only after validating its locked source state; `Reconsider(decision: "approve")` reacquires proof before leaving `rejected`.

- [x] **Step 1: Add failing lifecycle transition tests**

Extend release tests for code quantity and invitation state, including same-key replay/no double return and SQL-verified order/payment-before-registration lock ordering. Add reject tests for both proof types and rejection replay. Extend reconsideration tests to prove available proof is reacquired, exhausted/expired proof leaves status `rejected` with no approval audit, and reconsidering as reject does not return proof a second time.

- [x] **Step 2: Run transition tests and confirm they fail on current behavior**

Run: `bundle exec rails test test/services/ticketing/registrations/release_pending_test.rb test/services/ticketing/registration_decisions/reject_test.rb test/services/ticketing/registration_decisions/approve_test.rb`

Expected: proof counters/invitation states are not restored, and reconsideration does not reacquire proof.

- [x] **Step 3: Integrate release/reacquisition into existing transactions**

Acquire `orders-checkout` advisory lock before row locks in buyer release. Lock related orders and payment rows in statuses that block release, in deterministic order, before locking the registration; this matches payment acceptance's order/payment/registration order while avoiding locks on unrelated terminal payment evidence. After each valid terminal status update, call Task 1's release command with the parent command's stable transition key. Reconsideration approval must call reacquire with its stable transition key before mutating approval fields; propagate proof/audit failure so the enclosing transaction rolls back.

- [x] **Step 4: Run transition tests and confirm green**

Run: `bundle exec rails test test/services/ticketing/registrations/release_pending_test.rb test/services/ticketing/registration_decisions/reject_test.rb test/services/ticketing/registration_decisions/approve_test.rb`

Expected: all transitions are atomic; replays do not return proof twice; invalid reacquisition leaves the rejection intact.

### Task 3: Make final checkout expiry terminal and reject stale registrations

**Files:**
- Modify: `app/services/orders/release_checkout.rb`
- Modify: `app/services/orders/expire_checkout.rb`
- Modify: `app/services/orders/expire_settlement_grace.rb`
- Modify: `app/services/orders/build_quote.rb`
- Modify: `app/services/orders/create_checkout.rb`
- Modify: `db/migrate/20260811090002_create_order_items.rb`
- Modify: `db/structure.sql`
- Modify: `config/locales/orders/checkout.en.yml`
- Test: `test/services/orders/expire_checkout_test.rb`
- Test: `test/services/orders/expire_settlement_grace_test.rb`
- Test: `test/services/orders/build_quote_test.rb`
- Test: `test/services/orders/create_checkout_test.rb`
- Test: `test/services/orders/restart_checkout_test.rb`
- Test: `test/integration/orders/concurrent_checkout_test.rb`
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

**Interfaces:**
- Consumes `Ticketing::Registrations::AudienceProof::Release.call(registration:, reason:, transition_key:, at:)` from Task 1.
- Final `checkout_expired` closure changes linked `pending_payment` registrations to `expired` and releases proof; `buyer_requested` closure leaves the registration transition/compensation to `ReleasePending` in Task 2.
- New quotes and new checkout creation accept only `pending_payment` registrations. Existing exact-order replay remains ahead of new-checkout validation.

- [x] **Step 1: Add failing checkout-expiry and stale-registration tests**

Extend expiry tests so an order with no attempt expires its linked registration and releases code/invitation proof; a payment held in settlement grace keeps both registration and proof pending; verified payment success keeps proof consumed; and definitive settlement-grace release expires and compensates. Add quote/create tests that reject non-pending registrations and preserve an existing-order idempotent replay. Extend active restart coverage to prove a replacement checkout keeps the same pending registration/proof. Race duplicate final-expiry scans to prove concurrent compensation occurs once.

- [x] **Step 2: Run the focused order tests and confirm they fail**

Run: `bundle exec rails test test/services/orders/expire_checkout_test.rb test/services/orders/expire_settlement_grace_test.rb test/services/orders/build_quote_test.rb test/services/orders/create_checkout_test.rb test/services/orders/restart_checkout_test.rb test/integration/orders/concurrent_checkout_test.rb`

Expected: the new tests show orders closing without registration/proof lifecycle updates, stale registrations being accepted for new checkout, and ticket restart failing on the current global registration index.

- [x] **Step 3: Integrate final expiry with registration/proof lifecycle**

Acquire the shared checkout advisory lock at the start of `ExpireCheckout#expire_order` and `ExpireSettlementGrace`'s finalization transaction, before their first order/payment row lock; Task 2 does the same before `ReleasePending` locks its registration. Do not acquire it only after a row lock. In `ReleaseCheckout`, only for `reason == "checkout_expired"`, lock associated pending registrations in deterministic ID order, mark them `expired`, clear next-action state, record the transition, and call Task 1's release command. Change the original order-item unique index to `(registration_id, order_id)` for non-null registrations, preserving one registration line per order while allowing immutable items for closed and replacement orders. Keep the entire order, registration, proof, and audit update atomic.

- [x] **Step 4: Enforce payable registration state in quote and checkout paths**

Reject any newly quoted/created ticket checkout whose registration is not `pending_payment`, using a typed localized `registration_not_payable` error. Do not move the existing idempotent-order replay behind these new state checks. Preserve active checkout restart semantics.

- [x] **Step 5: Run focused order tests and confirm green**

Run: `bundle exec rails test test/services/orders/expire_checkout_test.rb test/services/orders/expire_settlement_grace_test.rb test/services/orders/build_quote_test.rb test/services/orders/create_checkout_test.rb test/services/orders/restart_checkout_test.rb test/integration/orders/concurrent_checkout_test.rb`

Expected: all focused order tests pass; settlement grace retains proof, final expiry returns it once, stale registrations cannot start a new checkout, and exact replay remains safe.

### Task 4: Final cross-flow verification and tracker closeout

**Files:**
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`
- Verify without changing: public RSVP, registration, guest checkout, resale reservation, payment expiry, Postman collection.

- [x] **Step 1: Run the complete affected test set**

Run:

```bash
bundle exec rails test \
  test/services/ticketing/registrations/audience_proof/release_test.rb \
  test/services/ticketing/registrations/audience_proof/reacquire_test.rb \
  test/services/ticketing/access_codes/consume_test.rb \
  test/services/ticketing/invitations/claim_test.rb \
  test/services/ticketing/audience/authorize_test.rb \
  test/integration/ticketing/public_rsvps_test.rb \
  test/services/ticketing/registrations/release_pending_test.rb \
  test/services/ticketing/registration_decisions/reject_test.rb \
  test/services/ticketing/registration_decisions/approve_test.rb \
  test/services/orders/expire_checkout_test.rb \
  test/services/orders/expire_settlement_grace_test.rb \
  test/services/orders/build_quote_test.rb \
  test/services/orders/create_checkout_test.rb \
  test/services/orders/restart_checkout_test.rb \
  test/integration/orders/concurrent_checkout_test.rb \
  test/integration/ticketing/registrations_test.rb \
  test/integration/orders/guest_checkout_test.rb \
  test/services/marketplace/reserve_listing_test.rb
```

Expected: zero failures/errors; exact totals are recorded in the tracker.

- [x] **Step 2: Run N+1, lint, load, and artifact checks**

Run the same test command from Step 1 with `N_PLUS_ONE=1`. Run:

```bash
bundle exec rubocop --cache false \
  app/services/ticketing/registrations/audience_proof/release.rb \
  app/services/ticketing/registrations/audience_proof/reacquire.rb \
  app/services/ticketing/access_codes/consume.rb \
  app/services/ticketing/invitations/claim.rb \
  app/services/ticketing/audience/authorize.rb \
  app/services/ticketing/rsvps/request_otp.rb \
  app/services/ticketing/registrations/release_pending.rb \
  app/services/ticketing/registration_decisions/reject.rb \
  app/services/ticketing/registration_decisions/reconsider.rb \
  app/services/orders/release_checkout.rb \
  app/services/orders/expire_checkout.rb \
  app/services/orders/expire_settlement_grace.rb \
  app/services/orders/build_quote.rb \
  app/services/orders/create_checkout.rb \
  test/services/ticketing/registrations/audience_proof/release_test.rb \
  test/services/ticketing/registrations/audience_proof/reacquire_test.rb \
  test/services/ticketing/access_codes/consume_test.rb \
  test/services/ticketing/invitations/claim_test.rb \
  test/services/ticketing/audience/authorize_test.rb \
  test/integration/ticketing/public_rsvps_test.rb \
  test/services/ticketing/registrations/release_pending_test.rb \
  test/services/ticketing/registration_decisions/reject_test.rb \
  test/services/ticketing/registration_decisions/approve_test.rb \
  test/services/orders/expire_checkout_test.rb \
  test/services/orders/expire_settlement_grace_test.rb \
  test/services/orders/build_quote_test.rb \
  test/services/orders/create_checkout_test.rb \
  test/services/orders/restart_checkout_test.rb \
  test/integration/orders/concurrent_checkout_test.rb
```

Also run `bin/rails zeitwerk:check`, `git diff --check`, and:

```bash
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "Postman collection JSON valid"'
```

Expected: all affected tests pass under N+1 detection; changed Ruby files have no RuboCop offenses; Zeitwerk and diff checks pass; the Postman JSON remains valid and unchanged by this internal lifecycle change.

- [x] **Step 3: Update G-34 and G-27 tracker status with verified counts**

Record local verification (119 tests/851 assertions, including N+1) and explicitly note that no Render deployment/E2E was performed. Leave all changes unstaged and uncommitted for the user to review.
