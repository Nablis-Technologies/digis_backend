# Gift Claim Review Follow-ups Implementation Plan

> **For agentic workers:** Execute inline in the current feature branch. Keep the existing worktree intact; do not stage or commit.

**Goal:** Make gift checkout replay report the recipient-consent action accurately, keep credential activation inside Ticketing, and remove avoidable duplication without weakening consent binding.

**Architecture:** `Orders::GiftPurchases::Claim` remains the commerce coordinator and calls the Ticketing package-issuance boundary. `Ticketing::Packages::Issue` and `Ticketing::CredentialGenerations::CreateInitialGroup` own issuance locks/context and reconcile an existing pending credential after requirements become satisfied. Admission-line input exposes one shared predicate for gift recipient data; slot-subject assignment remains in `BuildRequirements` because it binds the actor only after the exact admission coordinate has been selected, within the existing registration transaction.

**Tech Stack:** Rails 8.1, Active Record, Minitest, PostgreSQL, RuboCop.

---

### Task 1: Reproduce pending-consent checkout replay response

**Files:**
- Modify: `test/services/orders/admission_selections/create_test.rb`
- Modify: `app/services/orders/admission_selections/create.rb`
- Modify: `postman/Digis API_collection.json`

- [x] Add a regression test that creates a zero-total gift order, claims the gift into `pending_recipient_consent` using a required admission-slot consent, then replays the same checkout selection and idempotency key.
- [x] Run the focused regression and confirm it fails because replay reports `confirmed`, not `gift_claim_pending`.
- [x] In `result_for_order`, compute credential-bearing regular items once, restore small count helpers accepting those items, and classify gift states `ready` and `pending_recipient_consent` as `gift_claim_pending`. Remove the shadowed `pending_payment` gift branch.
- [x] Add a Postman response example for checkout replay while recipient consent is pending.
- [x] Re-run the focused test and full `create_test.rb`; both pass as part of the final regression run.

### Task 2: Make package-issuance replay reconcile pending credentials

**Files:**
- Modify: `test/services/ticketing/packages/issue_test.rb`
- Modify: `app/services/ticketing/credential_generations/create_initial_group.rb`
- Modify: `app/services/ticketing/packages/issue.rb`
- Modify: `app/services/orders/gift_purchases/claim.rb`

- [x] Add a test that issues a package with a pending admission-slot requirement, accepts that requirement through `Ticketing::Consent::BuildRequirements`, retries package issuance, and asserts the same ticket now has an active QR credential and attendee-index projection.
- [x] Run the focused test and confirm it fails because replay currently returns the ticket without activating the pending credential.
- [x] Let `CreateInitialGroup` reconcile an existing pending generation using its existing activation eligibility checks; preserve the `qr_and_id` and pending-consent gates.
- [x] Let `Packages::Issue` acquire package/index advisory locks and build reserved lookup-code context when no context is supplied; preserve the existing caller-supplied-context contract, skip that work for already-active replays, and refuse reconciliation after event cancellation or ticket deactivation.
- [x] Add a regression test proving an accepted-but-pending credential is not activated by replay after its event is cancelled.
- [x] Remove Orders' direct credential query, lookup-code context construction, and `Credentials::Activate` call. Orders now calls `Packages::Issue` with the order item and event only.
- [x] Run the package-issue and gift-claim tests; existing activation behavior remains green.

### Task 3: Share the gift recipient-data invariant and clarify consent binding

**Files:**
- Modify: `app/values/orders/admission_selection_envelope.rb`
- Modify: `test/values/orders/admission_selection_envelope_test.rb`
- Modify: `app/services/orders/admission_selections/validate_line.rb`
- Modify: `app/services/orders/admission_selections/registration_assembler.rb`
- Modify: `app/services/ticketing/consent/build_requirements.rb`

- [x] Add a value-object test proving a normalized selection item reports whether recipient registration data is present.
- [x] Run the focused value-object test and confirm the predicate is missing.
- [x] Add one predicate to the immutable admission item and use it from both gift-line validation paths; keep both call sites so direct assembler use remains protected.
- [x] Correct `validate_line.rb` indentation while editing it.
- [x] Extract the admission-slot subject assignment into a named private helper in `BuildRequirements`, with a short comment documenting that exact coordinate selection and assignment occur in the same locked transaction before acceptance. Generic `Consent::Accept` does not auto-assign a subject.
- [x] Run the value-object, admission-selection, and consent tests.

### Task 4: Verify the combined change

**Files:**
- No additional file changes unless verification exposes a regression.

- [x] Run the focused gift purchase, admission-selection, package issuance, and consent suites with `N_PLUS_ONE=1` (91 tests, 894 assertions, all passing).
- [x] Run `bundle exec rubocop --cache false` on all changed Ruby files and `git diff --check`.
- [x] Review the final diff and ensure no unrelated dirty files were altered, staged, or committed.
