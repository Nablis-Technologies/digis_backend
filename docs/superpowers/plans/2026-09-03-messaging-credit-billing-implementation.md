# Messaging Credit and Billing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable, organization-scoped SMS/email credits with safe
Chapa/Orders top-ups and reservation settlement, without coupling campaign
spend to organizer event-finance ledgers.

**Architecture:** Messaging owns rate versions, credit accounts, reservations,
and the append-only credit ledger. Orders owns the billing-purchase/payment
boundary and reuses the existing provider adapter and provider-event inbox;
accepted top-up payments publish a durable event that Messaging consumes. The
future Campaigns plan will call the reservation commands and notification
delivery seam but is not implemented here.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL UUIDv7/check constraints/
triggers, Pundit, ActiveModelSerializers, Solid Queue, Minitest, Prosopite,
existing `Core::JsonResponse`, `Core::Pagination`, `Core::IdempotencyKey`,
`Core::Outbox`, and `Payments::Providers` contracts.

**Design spec:** `docs/superpowers/specs/2026-09-03-messaging-credit-billing-design.md`

## Current implementation checkpoint (2026-09-04)

Tasks 1–10 are implemented in the working tree: credit/rate persistence,
atomic reservation commands, Orders billing-payment subjects, Chapa-compatible
top-ups, delivery settlement, reconciliation jobs, APIs, seeds, and Postman
examples. Task 11's focused and full-suite acceptance gates are green; the
repository owner's staging/commit/merge checkpoint remains user-owned.

---

## Scope guard

This plan implements only credit/rate/top-up infrastructure. It does not add
campaigns, audience snapshots, marketing consent, templates, tracking links,
or SMS/email provider credentials. Do not use `Finance::LedgerEntry` for credit
balances and do not make transactional `Messaging::Notification` rows
chargeable.

## File map

### Messaging persistence

- Create: `db/migrate/20260904090001_create_messaging_credit_accounts.rb`
- Create: `db/migrate/20260904090002_create_messaging_credit_rate_versions.rb`
- Create: `db/migrate/20260904090003_create_messaging_credit_ledger_entries.rb`
- Create: `db/migrate/20260904090004_create_messaging_credit_reservations.rb`
- Create: `db/migrate/20260904090005_create_messaging_credit_top_ups.rb`
- Create: `app/models/messaging/credit_account.rb`
- Create: `app/models/messaging/credit_rate_version.rb`
- Create: `app/models/messaging/credit_ledger_entry.rb`
- Create: `app/models/messaging/credit_reservation.rb`
- Create: `app/models/messaging/credit_top_up.rb`
- Modify: `db/structure.sql`

The `orders_billing_purchases` migration uses the valid
`20260811085959` version and runs before the existing Orders payment migration
on a fresh database. The five `20260904...` Messaging migrations run after the
Orders tables and can reference the completed billing-purchase subject. Every
migration creates exactly one table. If `orders_payments` needs new billing
columns or constraints, edit its original migration rather than creating a
follow-up migration for that existing table; the preview database must be
rebuilt before verification.

### Rates and ledger commands

- Create: `app/services/messaging/resolve_credit_rate.rb`
- Create: `app/services/messaging/estimate_credit_top_up.rb`
- Create: `app/services/messaging/create_credit_top_up.rb`
- Create: `app/services/messaging/grant_top_up_credits.rb`
- Create: `app/services/messaging/credit_accounts/reserve.rb`
- Create: `app/services/messaging/credit_accounts/release.rb`
- Create: `app/services/messaging/credit_accounts/consume.rb`
- Create: `app/services/messaging/credit_accounts/refund.rb`
- Create: `app/services/messaging/credit_accounts/adjust.rb`
- Create: `app/services/messaging/credit_accounts/apply_delivery_result.rb`
- Create: `app/services/messaging/credit_accounts/balance_report.rb`
- Create: `app/services/messaging/credit_rates/create.rb`
- Create: `app/services/messaging/credit_rates/activate.rb`
- Create: `app/services/messaging/credit_rates/retire.rb`

### Orders/Chapa billing boundary

- Create: `db/migrate/20260811085959_create_orders_billing_purchases.rb`
- Modify: `db/migrate/20260811090009_create_payments.rb` to add the nullable
  `billing_purchase_id` foreign key and the exactly-one-payment-subject check.
- Create: `app/models/orders/billing_purchase.rb`
- Modify: `app/models/orders/payment.rb`
- Create: `app/services/orders/start_billing_payment_attempt.rb`
- Create: `app/services/orders/accept_billing_payment.rb`
- Modify: `app/services/orders/process_payment_event.rb`
- Reuse: `app/services/payments/providers/chapa_adapter.rb`; its existing
  provider contract remains unchanged and contains no credit math.
- Create: `app/services/messaging/outbox_handlers/grant_top_up_credits.rb`
- Create: `app/services/messaging/outbox_handlers/resolve_top_up_payment.rb`
- Modify: `config/initializers/messaging_outbox_handlers.rb`

The concrete subject shape is `Orders::BillingPurchase`. `Orders::Payment`
references exactly one of an event `order_id` or a `billing_purchase_id`; the
original payment migration is edited because the repository is pre-production
and preview databases are rebuilt for schema changes. The billing purchase
stores an allowlisted `source_type/source_id` pointing to the Messaging top-up,
while the top-up stores the billing purchase foreign key. This keeps one Orders
provider-event inbox and one payment state machine without creating an event or
ticket solely to reuse checkout.

### API, admin, jobs, and contracts

- Create: `app/controllers/messaging/credit_accounts_controller.rb`
- Create: `app/controllers/messaging/credit_rates_controller.rb`
- Create: `app/controllers/messaging/credit_top_ups_controller.rb`
- Create: `app/controllers/messaging/credit_estimates_controller.rb`
- Create: `app/controllers/admin/messaging/credit_rates_controller.rb`
- Create: `app/controllers/admin/messaging/credit_adjustments_controller.rb`
- Create: `app/policies/messaging/credit_account_policy.rb`
- Create: `app/policies/messaging/credit_rate_policy.rb`
- Create: `app/policies/messaging/credit_top_up_policy.rb`
- Create: `app/policies/admin/messaging/credit_rate_policy.rb`
- Create: `app/policies/admin/messaging/credit_adjustment_policy.rb`
- Create: `app/serializers/messaging/credit_account_serializer.rb`
- Create: `app/serializers/messaging/credit_ledger_entry_serializer.rb`
- Create: `app/serializers/messaging/credit_rate_version_serializer.rb`
- Create: `app/serializers/messaging/credit_top_up_serializer.rb`
- Modify: `config/routes.rb`
- Create: `app/jobs/messaging/reconcile_credit_top_ups_job.rb`
- Create: `app/jobs/messaging/reconcile_credit_reservations_job.rb`
- Modify: `config/recurring.yml`
- Create: `config/locales/messaging/credits.en.yml`
- Modify: `postman/Digis API_collection.json`
- Modify: `db/seeds/base.rb` and `db/seeds/preview.rb`

### Tests

- Create: `test/models/messaging/credit_account_test.rb`
- Create: `test/models/messaging/credit_rate_version_test.rb`
- Create: `test/models/messaging/credit_ledger_entry_test.rb`
- Create: `test/models/messaging/credit_reservation_test.rb`
- Create: `test/models/messaging/credit_top_up_test.rb`
- Create: `test/services/messaging/resolve_credit_rate_test.rb`
- Create: `test/services/messaging/estimate_credit_top_up_test.rb`
- Create: `test/services/messaging/credit_accounts/reserve_test.rb`
- Create: `test/services/messaging/credit_accounts/release_test.rb`
- Create: `test/services/messaging/credit_accounts/consume_test.rb`
- Create: `test/services/messaging/credit_accounts/refund_test.rb`
- Create: `test/services/messaging/credit_accounts/adjust_test.rb`
- Create: `test/services/messaging/credit_accounts/apply_delivery_result_test.rb`
- Create: `test/services/messaging/create_credit_top_up_test.rb`
- Create: `test/services/messaging/grant_top_up_credits_test.rb`
- Create: `test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb`
- Create: `test/services/messaging/outbox_handlers/resolve_top_up_payment_test.rb`
- Create: `test/services/orders/start_billing_payment_attempt_test.rb`
- Create: `test/services/orders/accept_billing_payment_test.rb`
- Modify: `test/services/orders/process_payment_event_test.rb`
- Create: `test/jobs/messaging/reconcile_credit_top_ups_job_test.rb`
- Create: `test/jobs/messaging/reconcile_credit_reservations_job_test.rb`
- Create: `test/integration/messaging/credit_accounts_test.rb`
- Create: `test/integration/messaging/credit_rates_test.rb`
- Create: `test/integration/messaging/credit_top_ups_test.rb`
- Create: `test/integration/admin/messaging/credit_rates_test.rb`

---

## Task 1: Lock the database contract with failing schema tests

**Files:** The five Messaging migrations, schema tests, and `db/structure.sql`.

- [ ] **Step 1: Write failing schema assertions**

Assert one table per migration, UUIDv7 IDs, all foreign keys, channel/status
checks, positive quantities, signed `available_delta`, unique account scope,
unique rate version scope, unique ledger idempotency scope, reservation
identity uniqueness, and top-up idempotency uniqueness. Add a PostgreSQL trigger
test proving an inserted ledger entry cannot be updated or deleted.

- [ ] **Step 2: Run RED**

Run:

```bash
N_PLUS_ONE=1 bin/rails test test/models/messaging/credit_account_test.rb \
  test/models/messaging/credit_ledger_entry_test.rb
```

Expected: failures because the tables and models do not exist.

- [ ] **Step 3: Implement the five Messaging migrations**

Use explicit checks and indexes. Rate versions must include a nullable
`organization_id` FK and unique version identity by organization/channel/
country. The ledger table must include an immutable `available_delta` and a
unique `(credit_account_id, entry_type, idempotency_key_digest)` boundary.
Reservations must use `source_type/source_id` (not a future Campaigns FK), a
partial unique source identity by channel, and a check that `resolved_at` is
present only for terminal states.

- [ ] **Step 4: Run schema GREEN and inspect the structure dump**

Run:

```bash
bin/rails db:drop db:create db:migrate
N_PLUS_ONE=1 bin/rails test test/models/messaging/credit_account_test.rb \
  test/models/messaging/credit_ledger_entry_test.rb
rg -n "messaging_credit_|orders_billing|ledger.*immutable" db/structure.sql
```

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260904090001_create_messaging_credit_accounts.rb \
  db/migrate/20260904090002_create_messaging_credit_rate_versions.rb \
  db/migrate/20260904090003_create_messaging_credit_ledger_entries.rb \
  db/migrate/20260904090004_create_messaging_credit_reservations.rb \
  db/migrate/20260904090005_create_messaging_credit_top_ups.rb \
  app/models/messaging/credit_account.rb \
  app/models/messaging/credit_rate_version.rb \
  app/models/messaging/credit_ledger_entry.rb \
  app/models/messaging/credit_reservation.rb \
  app/models/messaging/credit_top_up.rb \
  test/models/messaging/credit_account_test.rb \
  test/models/messaging/credit_ledger_entry_test.rb db/structure.sql
git commit -m "feat(messaging): add credit and rate persistence boundaries"
```

## Task 2: Implement immutable rate versions and deterministic resolution

**Files:** `app/services/messaging/resolve_credit_rate.rb`,
`app/services/messaging/estimate_credit_top_up.rb`, rate models/tests, locales.

- [ ] **Step 1: Add rate resolver RED cases**

Cover organization/country/channel, global country/channel, organization
default, global default precedence; effective intervals; volume tiers;
currency mismatch; overlapping active versions; missing rate; and quantity
boundary behavior. Use `assert_idempotent` for repeated estimates where a
side-effect counter is involved and never use floats.

- [ ] **Step 2: Implement `ResolveCreditRate`**

Return a typed result containing the rate version, selected tier, unit price,
currency, and canonical resolver inputs. Return `rate_unavailable` for zero or
multiple matches; never silently choose another currency or channel.

- [ ] **Step 3: Implement top-up estimation**

Validate positive integer quantity, call the resolver, calculate integer
`amount_minor`, and return the immutable rate/version snapshot without writing
an account or ledger row.

- [ ] **Step 4: Run rate tests and RuboCop**

```bash
N_PLUS_ONE=1 bin/rails test test/services/messaging/resolve_credit_rate_test.rb \
  test/services/messaging/estimate_credit_top_up_test.rb \
  test/models/messaging/credit_rate_version_test.rb
bundle exec rubocop app/services/messaging/resolve_credit_rate.rb \
  app/services/messaging/estimate_credit_top_up.rb \
  app/models/messaging/credit_rate_version.rb
```

- [ ] **Step 5: Commit**

```bash
git add app/services/messaging/resolve_credit_rate.rb \
  app/services/messaging/estimate_credit_top_up.rb \
  app/models/messaging/credit_rate_version.rb \
  test/services/messaging/resolve_credit_rate_test.rb \
  test/services/messaging/estimate_credit_top_up_test.rb \
  test/models/messaging/credit_rate_version_test.rb \
  config/locales/messaging/credits.en.yml
git commit -m "feat(messaging): add versioned credit rate resolution"
```

## Task 3: Add account balance derivation and atomic ledger commands

**Files:** Account command classes, model tests, and shared idempotency helpers.

- [ ] **Step 1: Write RED ledger transition tests**

Prove grants, adjustments, reservations, releases, consumption, refunds, and
expiry append one row; duplicate keys replay; conflicting identities return
`idempotency_conflict`; insufficient funds return `insufficient_credits`; and
ledger rows cannot be edited. Add a separate-connection race test that attempts
two reservations against the same available quantity and proves one fails.

- [ ] **Step 2: Implement deterministic account locking**

Lock the `Messaging::CreditAccount` first, derive available credits from
immutable ledger entries, then lock active reservations in reservation-ID
order. Use one transaction and the shared `Core::IdempotencyKey`. Provider calls
are not allowed in these commands.

- [ ] **Step 3: Implement reserve/release/consume/refund/adjust**

Each command appends evidence and transitions one reservation where applicable.
Suppression releases the full hold; consume appends a zero-delta terminal row;
permanent provider failure restores the hold through a refund row. Manual
adjustment requires a reason and platform-admin authorization.

- [ ] **Step 4: Run race and focused tests**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/messaging/credit_accounts \
  test/models/messaging/credit_ledger_entry_test.rb \
  test/models/messaging/credit_reservation_test.rb
```

- [ ] **Step 5: Commit**

```bash
git add app/services/messaging/credit_accounts \
  app/models/messaging/credit_account.rb \
  app/models/messaging/credit_ledger_entry.rb \
  app/models/messaging/credit_reservation.rb \
  test/services/messaging/credit_accounts \
  test/models/messaging/credit_ledger_entry_test.rb \
  test/models/messaging/credit_reservation_test.rb
git commit -m "feat(messaging): add atomic credit ledger transitions"
```

## Task 4: Add rate administration and safe balance reporting

**Files:** Rate commands, serializers, policies, controllers, routes, locales,
and integration tests.

- [ ] **Step 1: Write RED API tests**

Cover organization read access, cross-organization denial, platform-admin draft
creation, activation overlap rejection, retirement, manual adjustment reason,
pagination/filter/order, missing `Idempotency-Key` returning `400`, and absence
of provider credentials, raw metadata, and other tenant balances. Include the
organizer rate-list contract at
`GET /organizations/:organization_id/messaging/credit_rates` and assert that
organizers cannot activate or retire a rate.

- [ ] **Step 2: Implement rate commands and policies**

Only admins activate/retire rates. Organizers can read the rate selected for
their organization. Every action has explicit serializer `VISIBILITY`,
`eager_load_config`, `allowed_order_columns`, `model_params`, and
`serializer_profile` entries. `CreditEstimatesController` authorizes
`Messaging::CreditTopUpPolicy#estimate?`, sharing the same organization
membership boundary as top-up creation.

- [ ] **Step 3: Implement account/ledger serializers and controllers**

Return separate `sms` and `email` summaries with available, reserved, consumed,
and refunded quantities. Ledger rows expose only safe numeric/type/reference
summaries. Use `Core::JsonResponse`, `Core::Pagination`, `Core::Filterable`,
and localized errors.

- [ ] **Step 4: Run integration and N+1 gates**

```bash
N_PLUS_ONE=1 bin/rails test test/integration/messaging/credit_accounts_test.rb \
  test/integration/messaging/credit_rates_test.rb
bundle exec rubocop app/controllers/messaging app/controllers/admin/messaging \
  app/serializers/messaging app/policies/messaging app/policies/admin/messaging
```

- [ ] **Step 5: Commit**

```bash
git add app/controllers/messaging app/controllers/admin/messaging \
  app/serializers/messaging app/policies/messaging app/policies/admin/messaging \
  config/routes.rb config/locales/messaging/credits.en.yml \
  test/integration/messaging/credit_accounts_test.rb \
  test/integration/messaging/credit_rates_test.rb
git commit -m "feat(messaging): expose safe credit and rate administration APIs"
```

## Task 5: Establish the Orders billing-purchase subject

**Files:** `db/migrate/20260811085959_create_orders_billing_purchases.rb`,
`db/migrate/20260811090009_create_payments.rb`, Orders models, and billing
command tests.

- [ ] **Step 1: Add the billing-purchase schema tests**

Assert the `orders_billing_purchases` table has an organization FK, an
allowlisted `source_type`, immutable currency/amount snapshots, lifecycle
statuses, and a unique idempotency digest. Assert `orders_payments` has a
nullable `billing_purchase_id` FK and a database check requiring exactly one of
`order_id` or `billing_purchase_id`, parallel attempt/accepted/current indexes,
and subject-appropriate digest checks. Assert the original payment snapshot
trigger validates order amount/currency for order payments and billing-purchase
amount/currency/price digest for billing payments.

- [ ] **Step 2: Write RED billing payment tests**

Cover payment amount/currency snapshots, provider idempotency, accepted,
failed, cancelled, unknown, and late-reversal outcomes. Existing event-order
payment tests must remain green.

- [ ] **Step 3: Implement the billing subject and payment commands**

Add `Orders::StartBillingPaymentAttempt` and `Orders::AcceptBillingPayment`
using the existing `Payments::Providers::Registry`, canonical provider result,
and provider-event identity. Accepted billing payments publish
`orders.billing_payment.accepted`; failed and late-reversed billing payments
publish `orders.billing_payment.failed` and `orders.billing_payment.reversed`.
Accepted billing payments must not fulfill tickets or mutate
`Finance::LedgerEntry`. Audit every existing payment service that dereferences
`payment.order` (`CreatePaymentReversal`, `ExpireSettlementGrace`,
`AcceptPayment`, notification projections, and any caller found by the impact
search) and keep event-order-only commands from receiving billing payments.
`ProcessPaymentEvent#publish_failure!` must use `payment.order&.event_id`, add
`billing_purchase_id` when present, and publish `orders.billing_payment.failed`
for billing subjects instead of sending a billing failure through the
event-order notification path. Make `commercial_signature` nullable for billing
payments, add the `billing_purchase_price_digest` snapshot, and require the
subject-appropriate digest with a database check. Add the parallel billing
purchase attempt/accepted/current indexes and branch the original snapshot
trigger before it queries `orders_orders`.

- [ ] **Step 4: Run Orders regressions**

```bash
N_PLUS_ONE=1 bin/rails test test/services/orders test/models/orders \
  test/integration/orders
```

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260811085959_create_orders_billing_purchases.rb \
  db/migrate/20260811090009_create_payments.rb \
  app/models/orders/payment.rb \
  app/models/orders/billing_purchase.rb \
  app/services/orders/start_billing_payment_attempt.rb \
  app/services/orders/accept_billing_payment.rb \
  app/services/orders/process_payment_event.rb \
  db/structure.sql \
  test/services/orders/start_billing_payment_attempt_test.rb \
  test/services/orders/accept_billing_payment_test.rb \
  test/services/orders/process_payment_event_test.rb
git commit -m "feat(orders): add a non-event billing purchase boundary"
```

## Task 6: Implement top-up creation and exactly-once credit grants

**Files:** Top-up command/model, Messaging outbox handler, Chapa integration
tests, and locales.

- [ ] **Step 1: Write RED top-up tests**

Prove estimation snapshots the rate and amount, duplicate creation replays,
conflicting request identity returns `409`, payment is required before credit,
accepted payment grants exactly once, and a late reversal appends a
compensating entry without deleting the grant. Use `assert_idempotent` and
`assert_audit_idempotent` where each guarantee applies.

- [ ] **Step 2: Implement `CreateCreditTopUp`**

Authorize the organization member, call the estimator, persist the immutable
top-up, and create a billing payment attempt through Task 5. No credit ledger
row is written at this point.

- [ ] **Step 3: Implement the accepted-payment outbox handler**

Register the grant handler for the explicit `orders.billing_payment.accepted` event.
Its payload contains `payment_id`, `billing_purchase_id`,
`source_type: "Messaging::CreditTopUp"`, `source_id`, `amount_minor`, and
`currency`. The handler loads IDs from the outbox, locks the top-up/account,
verifies payment identity, appends one grant, and marks the top-up paid.
Replays return the existing grant; cross-organization or amount mismatch is a
typed conflict. Register `ResolveTopUpPayment` for
`orders.billing_payment.failed` and `orders.billing_payment.reversed` so a
billing failure never enters the event-order notification path and a late
reversal appends the compensating credit evidence exactly once.

- [ ] **Step 4: Run focused outbox/top-up tests**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/messaging/create_credit_top_up_test.rb \
  test/services/messaging/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/resolve_top_up_payment_test.rb \
  test/services/orders/start_billing_payment_attempt_test.rb \
  test/services/orders/accept_billing_payment_test.rb
```

- [ ] **Step 5: Commit**

```bash
git add app/models/messaging/credit_top_up.rb \
  app/services/messaging/create_credit_top_up.rb \
  app/services/messaging/grant_top_up_credits.rb \
  app/services/messaging/outbox_handlers/resolve_top_up_payment.rb \
  app/services/messaging/outbox_handlers/grant_top_up_credits.rb \
  config/initializers/messaging_outbox_handlers.rb \
  test/services/messaging/create_credit_top_up_test.rb \
  test/services/messaging/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/grant_top_up_credits_test.rb \
  test/services/messaging/outbox_handlers/resolve_top_up_payment_test.rb
git commit -m "feat(messaging): grant credits from accepted billing payments"
```

## Task 7: Add reservation lifecycle contracts for Campaigns

**Files:** Reservation command interfaces, a standalone settlement command,
contract tests, and notification-delivery integration tests. No campaign
tables are created.

- [ ] **Step 1: Write RED delivery mapping tests**

Use a fake adapter and a fake campaign-recipient identity to prove suppression
releases credit without a provider call, success consumes once, retryable
failure retains the reservation, permanent failure refunds it, and repeated
delivery callbacks cannot resolve a reservation twice.

- [ ] **Step 2: Implement the standalone reservation settlement command**

Create `Messaging::CreditAccounts::ApplyDeliveryResult` with an interface that
accepts reservation ID, canonical delivery result, and idempotency identity.
It transitions only credit reservations and appends ledger evidence. The
future Campaigns delivery coordinator calls this command after it invokes the
existing `Messaging::DeliverNotification` contract; `deliver_notification.rb`
is not modified and transactional notifications never consume credits.

- [ ] **Step 3: Run contract tests**

```bash
N_PLUS_ONE=1 bin/rails test test/services/messaging/credit_accounts \
  test/services/messaging/credit_accounts/apply_delivery_result_test.rb \
  test/services/messaging/deliver_notification_test.rb \
  test/models/messaging/credit_reservation_test.rb
```

- [ ] **Step 4: Commit**

```bash
git add app/services/messaging/credit_accounts \
  app/models/messaging/credit_reservation.rb \
  test/services/messaging/credit_accounts \
  test/services/messaging/credit_accounts/apply_delivery_result_test.rb
git commit -m "feat(messaging): connect delivery outcomes to credit reservations"
```

## Task 8: Add bounded reconciliation jobs

**Files:** Reconciliation jobs, recurring schedule, job tests, locales.

- [ ] **Step 1: Write RED crash/retry tests**

Cover paid top-ups without grants, stale reservations, duplicate job execution,
provider result uncertainty, and one poisoned row not starving later rows.

- [ ] **Step 2: Implement jobs**

Jobs accept IDs and cursors only, use short claims and `FOR UPDATE SKIP LOCKED`,
append compensating evidence through commands, and aggregate typed failures.
They never edit ledger history or infer provider liquidity.

- [ ] **Step 3: Schedule and verify**

```bash
N_PLUS_ONE=1 bin/rails test test/jobs/messaging/reconcile_credit_top_ups_job_test.rb \
  test/jobs/messaging/reconcile_credit_reservations_job_test.rb
bin/rails runner 'YAML.load_file("config/recurring.yml")'
```

- [ ] **Step 4: Commit**

```bash
git add app/jobs/messaging/reconcile_credit_top_ups_job.rb \
  app/jobs/messaging/reconcile_credit_reservations_job.rb \
  config/recurring.yml \
  test/jobs/messaging/reconcile_credit_top_ups_job_test.rb \
  test/jobs/messaging/reconcile_credit_reservations_job_test.rb
git commit -m "feat(messaging): reconcile credit top-ups and reservations"
```

## Task 9: Add top-up/account API contracts and Postman examples

**Files:** Messaging controllers/serializers/routes, integration tests, Postman,
and localized errors.

- [ ] **Step 1: Write RED integration coverage**

Cover estimate, create top-up, top-up status, balance, ledger pagination,
missing key, replay, conflict, organization authorization, and safe response
fields. Assert no provider secret, payment token, raw message, or Finance
ledger field appears.

- [ ] **Step 2: Implement endpoints**

Use the routes specified in the design:

```text
GET  /organizations/:organization_id/messaging/credits
GET  /organizations/:organization_id/messaging/credit_ledger
GET  /organizations/:organization_id/messaging/credit_rates
POST /organizations/:organization_id/messaging/credit_estimates
POST /organizations/:organization_id/messaging/credit_top_ups
GET  /organizations/:organization_id/messaging/credit_top_ups/:id
GET  /admin/messaging/credit_rates
POST /admin/messaging/credit_rates
POST /admin/messaging/credit_rates/:id/activate
POST /admin/messaging/credit_rates/:id/retire
POST /admin/organizations/:organization_id/messaging/credit_adjustments
```

`CreditRatesController#index` uses the organization-scoped
`Messaging::CreditRateVersionPolicy` read action. `CreditEstimatesController` calls
`authorize` with `Messaging::CreditTopUpPolicy#estimate?`; all policy actions
have explicit serializer visibility and absent actions resolve to no fields.

- [ ] **Step 3: Synchronize Postman and run contract checks**

```bash
N_PLUS_ONE=1 bin/rails test test/integration/messaging/credit_accounts_test.rb \
  test/integration/messaging/credit_rates_test.rb \
  test/integration/messaging/credit_top_ups_test.rb \
  test/integration/admin/messaging/credit_rates_test.rb
```

- [ ] **Step 4: Commit**

```bash
git add app/controllers/messaging app/controllers/admin/messaging \
  app/serializers/messaging app/policies/messaging app/policies/admin/messaging \
  config/routes.rb postman/'Digis API_collection.json' \
  test/integration/messaging test/integration/admin/messaging
git commit -m "feat(messaging): add credit top-up and balance contracts"
```

## Task 10: Add deterministic preview fixtures and documentation

**Files:** `db/seeds/base.rb`, `db/seeds/preview.rb`, runbook/design references,
Postman response examples.

- [ ] **Step 1: Seed configurable rates and accounts**

Seed one global ETB SMS rate, one global ETB email rate, one volume tier, one
organization-specific override, separate accounts, and a paid top-up through
the real command boundary. Do not insert terminal reservation or delivery
states directly. Add the following base permission identities and assign only
the intended roles: `messaging_credit_account.index/show`,
`messaging_credit_top_up.create/show`, `messaging_credit_rate.index/show`,
`messaging_credit_rate.create/activate/retire`, and
`messaging_credit_adjustment.create`. Use the existing permission namespace
convention rather than introducing a second RBAC registry.

- [ ] **Step 2: Add seed convergence tests**

Run the seed twice and assert one rate version per fixture identity, one account
per channel, one top-up grant, and no duplicate ledger rows.

- [ ] **Step 3: Document the campaign handoff**

Update the Messaging notification plan and master roadmap to state that Credit/
Billing is accepted before Marketing Campaigns. Document suppression release,
channel-specific balances, rate precedence, and the no-Finance-ledger rule.

- [ ] **Step 4: Commit**

```bash
git add db/seeds/base.rb db/seeds/preview.rb \
  docs/superpowers/plans/2026-09-03-messaging-notification-foundation-implementation.md \
  docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md \
  postman/'Digis API_collection.json'
git commit -m "docs(messaging): add credit billing fixtures and handoff"
```

## Task 11: Final acceptance gate

- [x] **Step 1: Run focused Messaging/Orders tests with N+1 detection**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/models/messaging test/services/messaging test/jobs/messaging \
  test/integration/messaging test/integration/admin/messaging \
  test/services/orders test/models/orders test/integration/orders
```

- [x] **Step 2: Run quality and schema gates**

```bash
bundle exec rubocop --parallel
bin/brakeman --quiet --no-pager
bin/rails zeitwerk:check
bin/rails db:drop db:create db:migrate
git diff --check
```

- [x] **Step 3: Run the full suite**

```bash
N_PLUS_ONE=1 bin/rails test
```

Expected: zero failures and zero errors, with any existing skips explicitly
reported. Re-run the credit reservation race test three times.

- [x] **Step 4: Review the final diff**

Confirm no campaign tables, campaign consent, provider credentials, direct
Chapa calls from Messaging, Finance payout mutations, mutable credit balance,
or notification billing fields entered the branch.

- [ ] **Step 5: User-owned final commit checkpoint**

Do not stage or commit automatically. The repository owner reviews the grouped
commits and merges the plan before the separate Marketing Campaigns spec is
written.

## Completion handoff

After this plan is accepted and merged, review the campaign design and
implementation plan in
`docs/superpowers/specs/2026-09-05-marketing-campaigns-design.md` and
`docs/superpowers/plans/2026-09-06-marketing-campaigns-implementation.md`. That
separate plan owns campaign/audience/consent/template/schedule/link/analytics
tables and organizer/admin campaign APIs while consuming these credit and
notification contracts.
