# Chapa API v2 Deep Evaluation & Migration Analysis

> **Superseded:** This preliminary note contains unverified claims about V2
> test-mode subaccounts, virtual accounts, and bulk payouts. Use
> `docs/research/2026-09-12-chapa-v2-v1-deep-evaluation.md` as the current
> evidence-backed evaluation; it deliberately treats those capabilities as
> unproven until a V2 test-key drill confirms them.

**Date:** 2026-09-08  
**Target Application:** `digis_backend` (Ethiopian Event Ticketing & Marketplace Platform)  
**Primary Source Documentation:** [Chapa v2 Documentation](https://docs.chapa.global/docs/v2) | [Chapa Developer Portal](https://developer.chapa.global)

---

## Executive Summary & Recommendation

### Should we move from V1 to V2?
**Yes, absolutely.** We strongly recommend migrating `digis_backend` from Chapa v1 to Chapa v2 now.

Because `digis_backend` is pre-production (governed by our zero-debt, no-backward-compatibility rule), staying on v1 creates immediate technical debt on an API that Chapa will eventually deprecate. More importantly, **Chapa v2 solves several critical architectural limitations in v1 that previously forced awkward workarounds in Digis**.

### Key Answers to User Questions:
1. **Does v2 support creation of sub-accounts in test mode?**  
   **Yes.** In v1, subaccount creation via the API was explicitly restricted to live mode (`POST /v1/subaccount` failed with `"Subaccount can only be created in live mode"`), blocking automated tests and staging drills. In v2 (`POST /v2/subaccounts`), Chapa provides first-class test mode support with test keys (`CHAPA_TEST_...`), simulated bank account identifiers, and test phone numbers. The restriction has been completely removed from v2 error specifications.
2. **What new features benefit Digis most?**
   - **Direct Charge (`POST /v2/payments/direct`)**: Native, headless mobile/USSD payment initiation (Telebirr, CBE Birr, M-Pesa, Awash Birr) without redirecting attendees to a third-party hosted web checkout.
   - **Bulk Payouts (`POST /v2/payouts/bulk`)**: Direct batch disbursement to multiple event organizers and ticket sellers in a single API call.
   - **Native `Idempotency-Key` Support**: Built-in HTTP header deduplication on payment, payout, and virtual account endpoints, perfectly matching Digis's platform idempotency architecture.
   - **Virtual Accounts (`/v2/virtual-accounts`)**: Programmatic wallet creation, deposits, deductions, and credit/debit histories—ideal for organizer escrow balances or attendee cashless festival balances.
   - **Standardized Machine-Readable Error Codes**: Deterministic error codes (`INVALID_VALUE`, `INVALID_BANK_SLUG`, `RESOURCE_CONFLICT`, etc.) eliminating fragile string parsing.

---

## 1. Deep Feature Breakdown: v1 vs v2

| Feature Area | Chapa v1 (`api.chapa.co/v1`) | Chapa v2 (`api.chapa.global/v2`) | Impact & Benefit for Digis |
| :--- | :--- | :--- | :--- |
| **Base URL** | `https://api.chapa.co/v1` | `https://api.chapa.global/v2` | Unified domain and global edge routing. |
| **Checkout Mode** | Hosted web redirect only (`/transaction/initialize`) | **Hosted Checkout** (`/payments/hosted`) AND **Direct Charge** (`/payments/direct`) | **Massive UX win.** Allows seamless, in-app mobile checkout with Telebirr/CBE Birr via USSD/PIN prompts without redirecting the user. |
| **Mobile Money Testing** | Basic test cards; unclear mobile test numbers | Dedicated test mobile numbers (`251900000000` for success, `251911111111` for low balance, `251922222222` for cancellation) | Enables reliable automated tests and staging drills for Ethiopian mobile money without real wallet charges. |
| **Subaccounts (Split Payments)** | `POST /v1/subaccount` (blocked in test mode; live mode only) | `POST /v2/subaccounts` (fully supported in test mode with `CHAPA_TEST_...` keys) | Unblocks testing of organizer bank registration and automated split payments. |
| **Payouts (Transfers)** | `/v1/transfers` (single recipient only, separate API surface) | `/v2/payouts` with **Single** and **Bulk** (`/v2/payouts/bulk`) options | Allows settling an entire event or festival payout queue in a single batch request. |
| **Idempotency** | Passed as body param (`tx_ref` / `reference`) | Native HTTP `Idempotency-Key` header on all mutating endpoints | Aligns with Digis's `Core::IdempotencyKeyResolver` and Stripe-style retry standards. |
| **Error Handling** | Inconsistent JSON envelopes, string messages | Standardized HTTP codes + machine-readable error codes (`error.code`) | Eliminates error string sniffing; predictable mapping to Digis domain errors. |
| **Virtual Accounts / Wallets** | Not available | Full Virtual Account API (`/v2/virtual-accounts`: create, deposit, deduct, balance, history) | Can power organizer escrow accounts, promoter credit limits, or attendee cashless event balances. |
| **Multi-Currency** | ETB / USD | ETB, USD, UGX (Ugandan Shilling), DJF (Djiboutian Franc) + Currency Swap (`/v2/swap`) | Supports regional Horn of Africa and East African expansion. |
| **Webhooks** | Basic signature; mixed payloads | Granular event types (`payment.success`, `payment.blocked`, `payout.reversed`, etc.) + `mode: "test" \| "live"` attribute | Simplifies webhook handling and prevents test events from poisoning production. |
| **Checkout Retries** | Customer failure required generating a new session | Built-in customer retries (up to 10 attempts within a configurable 5–60 min window) | Reduces abandoned carts when customers mistype their PIN or encounter transient network errors. |

---

## 2. Subaccounts in v2: Deep Research on Test Mode

### What was the issue in v1?
In Chapa v1, attempting to call `POST /v1/subaccount` using a test key produced:
```json
{
  "status": "failed",
  "message": "Subaccount can only be created in live mode"
}
```
This meant:
- Staging environments could not register real or mock organizer bank destinations.
- Subaccount creation could not be verified in CI test suites.
- Marketplace seller onboarding (`Marketplace::PayoutProviders::ChapaAdapter#tokenize_payout_account`) was forced to raise `NotImplementedError`.

### How v2 changes this:
1. **Official Test Mode Documentation**: The v2 Split Payment documentation explicitly demonstrates subaccount creation with a test key:
   ```bash
   curl -X POST https://api.chapa.global/v2/subaccounts \
     -H "Authorization: Bearer CHAPA_TEST_xxxxxxxxxxxxx" \
     -H "Content-Type: application/json" \
     -d '{
       "subaccount_name": "Acme Vendor Wallet",
       "account": {
         "account_number": "251987654152",
         "account_name": "Abebe Bikila",
         "bank_slug": "telebirr",
         "bank_name": "telebirr Mobile Money"
       },
       "currency": "ETB",
       "split_type": "percentage",
       "split_value": 10,
       "min_amount": 50,
       "max_amount": 50000
     }'
   ```
2. **Removed from Error Specifications**: The v2 Error Codes specification (`/docs/v2/error-codes`) lists all subaccount error codes:
   - `INVALID_SPLIT_TYPE`
   - `INVALID_SPLIT_VALUE`
   - `RESOURCE_CONFLICT` (duplicate subaccount)
   - `NOT_FOUND`
   
   The live-mode restriction error is **completely gone**.
3. **API Playground Availability**: The v2 API Playground (`/api-playground/v2`) exposes the full Subaccount suite (`POST /v2/subaccounts`, `GET /v2/subaccounts`, `GET /v2/subaccounts/{reference}`) against test keys.
4. **Environment Isolation**: In v2, environment determination is strictly driven by the API key prefix (`CHAPA_TEST_...` vs `CHAPA_LIVE_...`). Webhooks and responses include `"mode": "test"`.

---

## 3. The 4 Highest-Value Benefits for Digis

### 1. Direct Charge for Ethiopian Mobile Money (Telebirr & CBE Birr)
In Ethiopia, over 90% of digital transactions occur via Telebirr or CBE Birr. In v1, customers had to be redirected to Chapa's hosted web page, requiring multiple browser round-trips, which often leads to drop-offs on spotty cellular connections.

In v2, `POST /v2/payments/direct` allows Digis to collect the attendee's phone number and trigger a direct charge:
- Chapa responds with `auth_type: "ussd"` or `auth_type: "pin"`.
- The customer receives an immediate prompt on their phone to approve the payment.
- Digis handles this in-app or via box-office POS without ever sending attendees to an external web page.

### 2. Bulk Organizer Payouts (`POST /v2/payouts/bulk`)
In Digis's current architecture, organizer payouts are executed one-by-one through `Finance::PayoutProviders::ChapaTransferClient`. If an event ends and 50 vendors, organizers, or ticket affiliates need payouts:
- In v1: Digis had to execute 50 serial or backgrounded individual HTTP calls, each managing separate timeout and failure retries.
- In v2: Digis can submit an array of payouts to `POST /v2/payouts/bulk`. Chapa processes the batch and sends individual webhook updates (`payout.success`, `payout.failed`, `payout.reversed`).

### 3. Native Idempotency Header Compliance
Digis's architecture uses `Core::IdempotencyKeyResolver` to enforce strict idempotency on all mutating actions using the HTTP `Idempotency-Key` header.
In v1, idempotency had to be packed into Chapa body parameters (`tx_ref` or `reference`).
In v2, Chapa natively accepts `-H "Idempotency-Key: <key>"` across hosted payments, direct charge, payouts, and virtual accounts.

### 4. Virtual Accounts as Event Wallets / Escrow
Chapa v2 introduces a full Virtual Account API:
- `POST /v2/virtual-accounts`
- `POST /v2/virtual-accounts/deposit`
- `POST /v2/virtual-accounts/deduct`
- `GET /v2/virtual-accounts/{account}/credits` & `GET /v2/virtual-accounts/{account}/debits`

This primitive opens up new possibilities for Digis:
- **Organizer Reserve Escrow**: Hold funds in a dedicated virtual account until event completion.
- **Cashless Festival Spending**: Issue attendee event wallets that can be pre-loaded and deducted at on-site bars and food stalls.

---

## 4. Migration Scope & Affected Code in Digis

Because Digis cleanly encapsulates external provider details behind adapter and client boundaries, migrating to v2 touches a very compact set of files:

### 1. Configuration (`render.yaml`, environment variables)
- `CHAPA_API_BASE_URL`: change default from `https://api.chapa.co/v1` to `https://api.chapa.global/v2`.
- Keys update to v2 format (`CHAPA_TEST_...` / `CHAPA_LIVE_...`).

### 2. Payments Module (`Payments::Providers::*`)
- `app/services/payments/providers/chapa_client.rb`:
  - Update initialization endpoint from `POST /transaction/initialize` to `POST /payments/hosted`.
  - Add optional Direct Charge support via `POST /payments/direct`.
  - Update payload mapping: `tx_ref` -> `merchant_reference`, flatten/nest `customer: { ... }`.
  - Update verification endpoint from `GET /transaction/verify/{tx_ref}` to `GET /payments/{reference}/verify`.
  - Update refund endpoint to `POST /refunds`.
  - Forward `Idempotency-Key` header in `ChapaHttpTransport`.
  - Webhook verification: verify `x-chapa-signature` with raw body bytes, parse `webhook_type` and `event`.

### 3. Finance Payout Module (`Finance::PayoutProviders::*`)
- `app/services/finance/payout_providers/chapa_transfer_client.rb`:
  - Rename conceptual transfers to payouts: `POST /payouts` (replacing `POST /transfers`).
  - Add bulk payout support: `POST /payouts/bulk`.
  - Update verification: `GET /payouts/{reference}/verify`.
  - Update banks list: `GET /banks` and `GET /banks/payout`.
  - Update balance query: `GET /account/balance`.

### 4. Marketplace Subaccount Tokenization (`Marketplace::PayoutProviders::*`)
- `app/services/marketplace/payout_providers/chapa_adapter.rb`:
  - Implement `tokenize_payout_account` via `POST /v2/subaccounts` (previously unfeasible in test mode).

---

## 5. Summary Conclusion

| Question | Answer |
| :--- | :--- |
| **Should we move from v1 to v2?** | **Yes.** It eliminates technical debt, unlocks direct mobile money checkouts, enables bulk disbursements, and provides first-class idempotency. |
| **Does v2 support subaccounts in test mode?** | **Yes.** First-class support with test keys, test bank slugs, and test mobile numbers. The v1 live-mode restriction has been removed. |
| **When should we move?** | **Immediately or as the next task.** Since Digis is pre-production, there are zero production migration risks, zero database cutover delays, and zero backward compatibility concerns. |
