# Chapa Payout Transfer Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-shaped Chapa bank-transfer client behind the existing Finance payout-provider boundary for deterministic test-mode verification.

**Architecture:** Keep pay-in/refund behavior in `Payments::Providers::ChapaClient`. Add a separate `Finance::PayoutProviders::ChapaTransferClient` for Chapa transfer initialization, transfer verification, and balance reads. Register it only when payout integration is explicitly enabled. Do not add organizer beneficiary storage in this tranche because the canonical Finance payout schema has no verified destination contract yet.

**Tech Stack:** Ruby 3.4, Rails 8.1, Minitest, injected HTTP transport, Chapa Transfer API.

---

### Task 1: Define the transfer client contract with failing tests

**Files:**
- Create: `app/services/finance/payout_providers/chapa_transfer_client.rb`
- Create: `test/services/finance/payout_providers/chapa_transfer_client_test.rb`

- [x] Cover the exact `POST /transfers` JSON contract: amount conversion from minor units, currency, account number, bank code, reference, and optional account name.
- [x] Cover `GET /transfers/verify/:reference` and `GET /balances/:currency`.
- [x] Cover success, failed, pending/queued, timeout, malformed response, and test/live key validation.

### Task 2: Implement the client and adapter wiring

**Files:**
- Modify: `app/services/finance/payout_providers/chapa_transfer_client.rb`
- Modify: `app/services/finance/payout_providers/chapa_adapter.rb`
- Modify: `app/services/finance/payout_providers/result.rb` only if provider mapping requires it

- [x] Keep provider payloads and HTTP details inside the transfer client.
- [x] Normalize provider references and statuses into `Finance::PayoutProviders::Result`.
- [x] Preserve unknown/timeout results so reconciliation never resubmits blindly.

### Task 3: Register the payout provider explicitly

**Files:**
- Create: `app/services/finance/payout_providers/registration.rb`
- Create: `config/initializers/finance_payout_providers.rb`
- Create: `test/config/finance_payout_providers_configuration_test.rb`
- Modify: `render.yaml`

- [x] Require `CHAPA_PAYOUT_ENABLED=true` in addition to the existing payment enablement.
- [x] Require test-mode keys in Render preview and never register live payout credentials there.
- [x] Keep secrets in environment configuration only; do not add them to seeds or Postman.

### Task 4: Verify and document the boundary

**Files:**
- Modify: `docs/guides/chapa-integration.md`
- Modify: `docs/runbooks/payout-hold-and-reconciliation.md`

- [x] Document that deterministic test outcomes use an injected transport; Chapa's test-mode status field is optional and not required by the application tests.
- [x] Document that organizer payout dispatch remains destination-gated until a verified organizer destination model exists.
- [x] Run focused tests with `N_PLUS_ONE=1`, RuboCop, syntax checks, targeted diff checks, and the relevant provider/config contract tests.

Verification: the focused provider/config/deployment suite passes 26 tests and
165 assertions, the final Chapa/Finance regression suite passes 46 tests and
287 assertions, and the final Finance suite passes 51 tests and 276 assertions
with N_PLUS_ONE=1. Full RuboCop and Zeitwerk checks also pass. The first
unsandboxed test attempt was blocked by the local PostgreSQL socket; the
escalated rerun passed. The repository-wide diff check still reports a
pre-existing extra blank line at EOF in the unrelated modified
db/structure.sql; targeted changed-file checks are clean.
