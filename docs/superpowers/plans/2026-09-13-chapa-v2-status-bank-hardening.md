# Chapa V2 Status and Bank Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Chapa V2 blocked payments retryable and make Ethiopian payout-bank validation match the documented active-bank contract.

**Architecture:** Preserve `unknown` as the non-terminal provider state for compliance and asynchronous outcomes. Keep bank-list provider details behind the Finance payout client, pass the Digis market country from account-registration commands, and do not invent undocumented cursor parameters.

**Tech Stack:** Rails 8.1, Ruby 3.4, Minitest, Chapa V2 REST API.

---

### Task 1: Preserve retryable blocked payment states

**Files:**
- Modify: `app/services/payments/providers/result.rb`
- Modify: `app/services/orders/process_payment_event.rb`
- Test: `test/services/payments/providers/chapa_client_test.rb`
- Test: `test/services/orders/process_payment_event_test.rb`

- [x] **Step 1: Add failing provider and webhook tests**

  Assert a V2 `blocked` payment maps to `unknown` with its reason/code
  preserved, and a `payment.blocked` webhook leaves the payment processing.

- [x] **Step 2: Remove terminal-failure mapping for blocked states**

  Map `blocked` to `unknown` in the canonical payment result and remove it
  from the terminal payment-event failure set.

- [x] **Step 3: Run the focused status tests**

  Expected: blocked payments remain eligible for verification and never fulfill.

### Task 2: Harden Ethiopian payout-bank validation

**Files:**
- Modify: `app/services/finance/payout_providers/chapa_payout_client.rb`
- Modify: `app/services/finance/payout_accounts/register.rb`
- Modify: `app/services/marketplace/verify_payout_account.rb`
- Test: `test/services/finance/payout_providers/chapa_payout_client_test.rb`
- Test: `test/services/finance/payout_accounts/register_test.rb`
- Test: `test/services/marketplace/verify_payout_account_test.rb`

- [x] **Step 1: Add failing active-bank, country, and case-normalization tests**

  Assert inactive banks are excluded, Finance and Marketplace request `country:
  "ET"`, and uppercase provider slugs match normalized input.

- [x] **Step 2: Filter inactive banks and pass the market country**

  Exclude entries with `is_active: false`, call the provider bank list with
  `country: "ET"`, and compare slugs case-insensitively. Do not add cursor
  requests because the published endpoint documents only the country input.

- [x] **Step 3: Run payout-account and bank-list tests**

  Expected: inactive and out-of-market destinations are not accepted while a
  provider outage still leaves account registration pending rather than
  authorizing dispatch.

### Task 3: Canonicalize provider amount and capability contracts

**Files:**
- Modify: `app/lib/core/json_number.rb`
- Modify: `app/services/payments/providers/chapa_client.rb`
- Test: `test/lib/core/json_number_test.rb`
- Test: `test/services/payments/providers/chapa_client_test.rb`

- [x] **Step 1: Add zero-amount and whole-number wire assertions**

  Reject zero payment amounts and assert whole major-unit values serialize as
  canonical JSON numbers without binary floating-point conversion.

- [x] **Step 2: Implement the exact boundary behavior**

  Require positive payment amounts and normalize redundant fractional zeroes in
  the Rails-safe JSON number value object.

- [x] **Step 3: Document deferred cancellation**

  Keep the registered `cancel: false` capability explicit in the V2 design
  documentation until a separate cancellation contract is proven.

### Task 4: Verify the complete scoped change

**Files:**
- Modify: `docs/superpowers/plans/2026-09-13-chapa-v2-status-bank-hardening.md`

- [x] **Step 1: Run the broad scoped Rails suite**

  Run the payment, payout, marketplace, order, controller, locale, Core, and
  seller payout-account test paths and require exit code 0.

- [x] **Step 2: Run static and contract checks**

  Run scoped RuboCop, Zeitwerk, `git diff --check`, Postman JSON parsing, and
  stale V1-reference searches.
