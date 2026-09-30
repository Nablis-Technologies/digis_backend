# G-26 Seller Payout Destination Discovery Implementation Plan

> Execute inline for the user's request. Preserve pre-existing work; do not stage, commit, deploy, seed, or initiate a payout.

**Goal:** Make seller payout setup use one authenticated, safe Chapa destination catalog and reject account registration whenever the provider's current discovery cannot establish an active ET/ETB bank or mobile-money destination.

**Architecture:** Add one Marketplace catalog service that normalizes provider bank-list entries and is shared by the seller discovery endpoint and account-registration command. Allow only the two Chapa V2 payout types explicitly documented by Chapa (`bank` and `mobile_money`), and pass the provider slug through the existing payout `bank_slug` mapping for both. Keep `store_value` and other provider types out of the model/catalog until Chapa documents and proves their payout mapping. Extend the Finance Chapa client to consume the documented response envelope safely; when the API reports another page but the request contract does not document a cursor parameter, fail closed instead of returning a partial catalog.

**Tech Stack:** Rails 8.1, Active Record, Minitest, Chapa V2 payout API.

---

### Task 1: Normalize and constrain the provider destination catalog

**Files:**
- Create: `app/services/marketplace/payout_providers/destination_catalog.rb`
- Test: `test/services/marketplace/payout_providers/destination_catalog_test.rb`
- Modify: `app/services/finance/payout_providers/chapa_payout_client.rb`
- Test: `test/services/finance/payout_providers/chapa_payout_client_test.rb`

- [x] Add tests for active `bank` and `mobile_money` + ETB + ET destination retention; rejection of inactive, `store_value`, unknown, and wrong-country/currency entries; distinguish a provider-unavailable `nil` response from a valid empty list.
- [x] Add Chapa client tests for the documented `data.items` + `data.pagination` envelope, the observed `data: []` envelope, inactive filtering, and fail-closed behavior when `has_more` is true or the response is malformed.
- [x] Run both focused test files and observe the new catalog/discovery assertions fail for the intended missing behavior.
- [x] Implement the minimal catalog normalization and bounded response parsing; preserve exact Chapa slugs while normalizing case for comparisons.
- [x] Re-run focused tests and require a complete, non-truncated catalog before reporting provider availability.

### Task 2: Reuse the catalog for registration and expose seller-safe discovery

**Files:**
- Modify: `app/services/marketplace/verify_payout_account.rb`
- Test: `test/services/marketplace/verify_payout_account_test.rb`
- Modify: `app/controllers/marketplace/seller_payout_accounts_controller.rb`
- Modify: `app/policies/marketplace/seller_payout_account_policy.rb`
- Modify: `config/routes.rb`
- Modify: `app/models/marketplace/seller_payout_account.rb`
- Modify: `db/migrate/20260814090001_create_marketplace_seller_payout_accounts.rb`
- Modify: `db/structure.sql`
- Test: `test/controllers/marketplace/seller_payout_accounts_controller_test.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `config/locales/marketplace/resale.en.yml`

- [x] Prove `nil`/unavailable discovery fails closed with a safe provider-unavailable result and never persists an account; prove a valid list rejects an absent, inactive, wrong-type, or wrong-market slug.
- [x] Add authenticated `GET /marketplace/seller/payout_accounts/destinations`, authorized using the seller's existing payout-account access policy, returning only provider, type, slug, display name, country, and currency.
- [x] Return a safe 503 when Chapa discovery is unavailable; keep a valid empty provider list as a successful empty collection.
- [x] Add route/API tests for auth, safe field projection, unsupported `store_value`, discovery outage, and accepted bank and mobile-money registration.
- [x] Add the route and response example to the existing Postman collection.

### Task 3: Verify, record scope, and leave integration gates explicit

**Files:**
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

- [x] Run focused marketplace payout tests, Chapa client tests, controller integration tests, and `N_PLUS_ONE=1` for changed HTTP paths: 48 tests / 244 assertions, 0 failures/errors.
- [x] Run RuboCop on every changed Ruby file: 14 files inspected, 0 offenses. `git diff --check` passes.
- [x] Run the broader related payout suite with `N_PLUS_ONE=1`: 165 tests / 783 assertions, 0 failures/errors/skips.
- [x] Update G-26 as implemented locally only after checks pass, while retaining the test-mode payout proof as pending (no financial dispatch performed).
- [x] Confirm `git status` and the final diff include the G-26 implementation/plan/tracker changes plus the pre-existing dirty files observed before work; preserve all unrelated changes.

---

## Self-review

- The controller listing and create validation consume the same normalized catalog, avoiding separate interpretations of Chapa's `type`, active flag, country, or currency fields.
- `mobile_money` maps through Chapa's documented `account.bank_slug` field; the original Marketplace account migration and SQL structure constraint accept only the two documented types. `store_value` remains excluded instead of being relabeled as either one.
- Chapa's docs show pagination metadata but do not specify a cursor request parameter. The implementation returns no partial list when another page exists; it does not invent a provider query parameter.
- Because the project edits original migrations, existing deployed databases that already recorded the old migration need a deliberate database rebuild from `db/structure.sql` before accepting `mobile_money`; no development or Render database was changed in this task.
- No payout dispatch, hosted checkout, development/Render database reset, migration execution, staging, commit, or deployment is part of this plan. The disposable `digis_backend_test` database was recreated from `db/structure.sql` to verify the expanded type check.
