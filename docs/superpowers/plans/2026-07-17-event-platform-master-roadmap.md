# Composable Event Platform Master Implementation Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved composable event, configurable organizer-commercials, commerce, ticketing, QR/offline scanning, settlement, resale, streaming, add-on, and link platform as independently testable Rails vertical slices.

**Architecture:** Build a modular monolith on the existing Rails namespaces and shared controller/policy/serialization infrastructure. Each write endpoint invokes one application command; commands own transactions, deterministic lock order, idempotency, and outbox publication, while models own persistence invariants and queries own reads. The approved database and QR documents remain normative; this roadmap decomposes them into an executable dependency order without legacy compatibility layers.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL with UUIDv7 primary keys, Pundit, ActiveModelSerializers, Active Record Encryption, Active Storage, Solid Queue, Minitest fixtures, Ed25519.

---

## Normative specifications

- `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`
- `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`
- `docs/superpowers/specs/2026-08-08-commercial-agreements-platform-pricing-design.md`

If a plan and a specification disagree, stop implementation and reconcile the plan with the specifications before writing production code. Do not silently reinterpret money, ticket, credential, refund, or offline-scanning invariants.

## Plan set and dependency order

| Order | Plan | Depends on | Working software produced |
|---:|---|---|---|
| 0 | `2026-07-17-event-platform-core-foundation.md` | Existing Core/Organizations/Events code | Shared result/error, money, advisory-lock, outbox, audit, encryption, namespace, and generator conventions |
| 1 | `2026-07-17-event-foundation-scheduling-media-implementation.md` | 0 | Draft/private/public events, collaborators/staff, dates, recurrence, media, schedule history, consent authoring |
| 2 | `2026-07-17-catalog-pricing-inventory-promotions-implementation.md` | 1 | Products, ticket settings, multi-currency prices, inventory/capacity, accesses/zones, minimal promotions |
| 3 | `2026-07-17-registration-consent-privacy-implementation.md` | 2 | Phone-first registration, approval/waitlist, forms/answers, consent, limits, retention, exports |
| 3.5 | `2026-08-08-commercial-agreements-platform-pricing-implementation.md` | 0, 1, 2, 3 | Platform defaults, programs, grants, negotiated agreements, deterministic fee resolution, simulation, subsidy budgets; order-linked reservations are handed off after Orders Task 2 |
| 4 | `2026-07-17-orders-payments-implementation.md` | 2, 3, 3.5, with the inter-plan handoff below | Immutable quotes/orders/commercial adjustments, payment attempts, webhooks, grace, accepted fulfillment boundary |
| 5 | `2026-07-17-ticket-packages-credentials-implementation.md` | 3, 4 | Commercial packages, slots, credential generations, QR/PNR, delegation, transfer, suspension |
| 6 | `2026-07-17-scanner-offline-admission-implementation.md` | 5 | Shared credential validator, admission use, devices, zones, offline sync/upload, manual lookup |
| 7 | `2026-07-17-refunds-finance-settlement-implementation.md` | 4, 5 | Cancellation/refunds, date-value allocation, liquidity, organizer ledger and payouts |
| 8 | `2026-07-17-controlled-resale-marketplace-implementation.md` | 4, 5, 7 | Whole-package marketplace, credential suspension/transfer, seller ledger and payouts |
| 9 | `2026-07-17-streaming-addons-links-implementation.md` | 2, 4, 5, 6 | Streaming sessions, parking and other add-ons, optional short links |
| 10 | `2026-07-17-launch-hardening-observability-implementation.md` | 0–9 | Security, reconciliation, performance, operations, contract tests, launch gates |

Resale is implemented after the package/credential core even though the schema document calls it Phase 3.75. Its reservation invariant cannot exist safely before generation revocation, package suspension, and replacement generation services.

### Commercial/Orders execution handoff

The plan-level table above is intentionally coarse. Commercial and Orders are
executed in this dependency order; do not treat either plan as an
all-or-nothing phase:

1. Complete Commercial Tasks 1–7A, including the hard per-currency subsidy
   budget invariant.
2. Complete Orders Tasks 1–2. Orders Task 2 owns the real `orders_orders`
   schema, model, constraints, and tests; do not create a placeholder table
   or seed order to unblock Commercial.
3. Complete Commercial Task 7B, which adds the order-linked subsidy
   reservation table with its restrictive foreign key to `orders_orders` and
   its transactional hold/processing/commit/release commands.
4. Complete Commercial Task 8, which adds the volume-usage and event-payer
   selection contracts consumed by checkout.
5. Implement Orders Task 3 together with Commercial Task 10's Orders
   integration contract. Checkout must not be considered complete until
   inventory, promotion, purchase-limit, volume, and subsidy reservations,
   immutable commercial adjustments, and accepted-order usage all pass their
   shared concurrency and idempotency tests.
6. Complete Orders Task 5, which owns the payment-attempt schema, canonical
   provider result/adapter contract, durable provider-event identity, and
   immutable Commercial-signature compatibility boundary.
7. Complete Orders Task 6, which owns starting and switching sequential
   payment attempts and making the actual provider calls under the Task 5
   contract. Do not treat the provider contract as payment orchestration.
8. Complete Orders Task 7, which owns the durable provider-webhook inbox,
   exactly-once accepted-payment boundary, full reversal obligations for
   losing or late successes, and the Orders fulfillment outbox event. It does
   not create placeholder Ticketing or Finance records.
9. Complete Orders Tasks 8–9 for expiry/settlement-grace behavior and the
   final Orders payment phase gate. Only then begin Ticket Packages Task 2.

Commercial Task 9 (admin and organizer API/UX) may follow its own documented
domain prerequisites, but it is not a reason to introduce a temporary
`orders_orders` table or to move 7B ahead of Orders Task 2.

**2026-08-13 execution checkpoint — follow this queue:**

- Commercial Tasks 1–10 are complete. The Commercial API, immutable checkout
  adjustment projection, provider contract, and sequential payment-attempt
  behavior are verified. Commercial Task 11 remains intentionally deferred to
  Controlled Resale; Task 12 remains last.
- Orders Tasks 1–9 are implemented and verified in the current branch,
  including checkout, payment-attempt persistence, provider compatibility,
  sequential attempt start/switch behavior, durable webhook receipt, exactly-
  once acceptance, full reversal obligations, the Orders fulfillment boundary,
  bounded checkout expiry/settlement grace, and the final repository gate. The
  prior Orders gate passed with 2,155 tests and 8,044 assertions. After
  Ticket Packages Tasks 2–4, the full `N_PLUS_ONE=1` suite passes with 2,179
  tests, 8,225 assertions,
  zero failures, and zero errors. The user review/commit remains pending.
- Ticket Packages Task 1 (schema/models) was committed early and is retained
  because it is a valid prerequisite. Tasks 2–6 (deterministic fulfillment
  issuance, credential generations, QR/PNR/index projection, delegation,
  claims, transfer, reversible suspension, terminal free-package invalidation,
  and the shared validator/revocation contract) are implemented and focused-
  verified in the current working tree. User review/commit remains pending.
- Scanner Tasks 1–8 (schema/models, device authorization, sync feeds, online
  admission, idempotent offline uploads, PNR/phone/audited lookup, immutable
  identity-mismatch override, append-only admission-use reversal, and the
  versioned native contract/scale gate) are implemented and Rails-focused-
  verified in the current working tree. User review/commit remains pending.
  The native client SQLite acceptance row remains open because no native
  scanner client is present in this repository.
- Refunds/Finance Tasks 1–8 (refund/cancellation schema, immutable refund-item
  scope, exact signed/date allocation, idempotent obligations, provider
  submission/reconciliation, soft-liquidity handling, crash recovery, package/
  date credential effects, the resumable event-cancellation coordinator, the
  append-only organizer ledger, locked event completion, maturity fan-out,
  payout allocation, provider adapters, reserve gates, and crash-safe
  reconciliation) are implemented and focused-verified with `N_PLUS_ONE=1`.
  Task 8 passes with 16 focused tests and 127 assertions, plus 7 completion/
  maturity/reserve-policy tests and the broader finance suite. Targeted Ruby
  files pass RuboCop, and the PostgreSQL structure dump contains the event
  completion field, ledger/payout tables, foreign keys, checks, and integrity/
  immutability triggers. User review/commit remains pending. Refunds/Finance
  Task 9 is implemented and focused-verified with `N_PLUS_ONE=1` in the
  current worktree: authorized refund status, ticket cancellation, organizer
  ledger/payout/balance views, and platform reserve/treasury controls are
  covered by 24 focused tests and 148 assertions, with safe buyer/organizer
  serialization, localized errors, routes, seeds, and Postman updates. User
  review/commit remains pending. Refunds/Finance Task 10 is now implemented
  and phase-gate verified: the final N+1-enabled full suite passes with 2,470
  tests and 9,842 assertions, all test migrations are up, and the required
  Orders/Finance/Ticketing race suite passes with 86 tests and 441 assertions.
  The user review/commit remains pending.
- Commercial Task 11 is implemented locally together with Controlled Resale
  Task 3. Its Marketplace adapter consumes Commercial's immutable
  `resale_platform_fee` result; listing/sale snapshot consumers remain in the
  later Controlled Resale tasks. User review/commit remains pending.
  Commercial Task 12 remains the last Commercial/Phase 3.5 gate.

The next human-visible action is therefore:

1. Review and commit the verified Orders, Ticket Packages, and Refunds/
   Finance tranches, including Finance Task 10. The native scanner SQLite
   acceptance row remains external and does not block the Rails Finance gate.
2. Keep the Scanner Task 8 contract files synchronized with the eventual
   Swift/Kotlin/Flutter client, then run that client-side SQLite acceptance
   gate when the client exists. It is independent of the next Rails task.
3. After Refunds/Finance Tasks 1–10 are green, run Controlled Resale Tasks 1–2
   and the Streaming /
   Add-ons / Links plan. These are Wave 6 work and may run in parallel when
   ownership is explicit.
4. Commercial Task 11 and Controlled Resale Task 3 are now complete locally;
   review/commit them, then execute Controlled Resale Task 4 and finish the
   remaining Controlled Resale tasks in order.
5. Execute Commercial Task 12 only after resale, Finance, and the required
   operational evidence exist.
6. Finish Launch Hardening only after all plans 0–9 are green.

Do not use a plan's numeric task number by itself as the next-task signal. Use
the current checkpoint above and the explicit gate at the top of each dependent
plan.

## Delivery waves and safe parallel work

| Wave | Work | Parallelism rule |
|---:|---|---|
| 0 | Core foundation | Run alone; every later plan consumes its contracts |
| 1 | Event foundation | Run alone until the event/date/access-zone schema is stable |
| 2 | Catalog, pricing, inventory, promotions | Run alone because registration and checkout both consume its immutable product contracts |
| 3 | Registration/consent/privacy, then Commercial, then orders/payments | Commercial follows registration and must freeze its resolver/adjustment contract before Orders; provider-adapter work may proceed only after the order/commercial projection interfaces are frozen |
| 4 | Ticket packages/credentials | Run alone until issuance and generation replacement pass their race tests |
| 5 | Scanner/offline admission and refunds/finance | May run in parallel after ticket credential interfaces are frozen; coordinate only package status/revocation hooks |
| 6 | Controlled resale and streaming/add-ons/links | May run in parallel after Wave 5, with resale owning package acquisition and streaming/add-ons consuming access validation |
| 7 | Launch hardening | Integrates all domains; no new product behavior is introduced here |

Parallel work must not create duplicate migrations or competing abstractions. Before two branches start, record which plan owns every shared table, command interface, outbox event, and configuration file. Merge the dependency owner first, rebase the consumer, and rerun both phase gates.

## Shared code rules

1. Keep `Core::Common` for ordinary CRUD only. Checkout, publication, cancellation, issuance, delegation, scanning, refunds, payouts, and resale each use a dedicated command.
2. A controller action authorizes, normalizes input, calls one command/query, and renders one result. It does not calculate money or coordinate multiple domain objects.
3. Reuse `Core::BaseService.call(...)`. Extend its result/error contract once in Plan 0; do not introduce Interactor, dry-rb, Trailblazer, or a second service framework.
4. Expected rejections return a typed `Core::BusinessError`; invariant or infrastructure failures raise namespaced exceptions and reach error reporting.
5. Commands own transactions and lock order. Active Record callbacks may maintain local counters or enqueue truly local after-commit work, but never orchestrate payment, inventory, ticket, revocation, refund, ledger, or payout workflows.
6. Persist retry identity at the aggregate table using the specification's unique idempotency key. `Core::IdempotencyKey` only normalizes/validates keys; it never replaces table-level uniqueness.
7. Publish side effects through `core_outbox_events` in the same transaction as authoritative state. Job arguments contain IDs, not secrets, answers, waiver contents, QR tokens, payout credentials, or full provider payloads.
8. Every business `type` model declares `self.inheritance_column = nil` and has an STI regression test.
9. Money is integer minor units plus ISO currency. FX uses `decimal(24,12)`. Ruby floats are prohibited in pricing, refunds, fees, ledgers, and payouts.
10. Public controllers remain serializer-controlled because `Public::ApplicationController` bypasses Pundit. Authenticated surfaces must align controller serializer profiles with policy visibility because `Core::JsonResponse` intersects them.
11. Sensitive attributes use Active Record Encryption and separate keyed digests only when exact lookup/deduplication is required.
12. PostgreSQL is the final correctness boundary for uniqueness, checks, exclusion constraints, partial indexes, and critical deferred cross-row invariants.
13. URL versioning (`/api/v1`) is **deferred** — pre-launch, no external consumers, so routes stay unversioned at root. When adopted later, `/api/v1` is a route `scope path:`, not a duplicate Ruby namespace. Controllers live under their domain (`Orders::`, `Ticketing::`, `Catalog::`, `Marketplace::`, `Finance::`, `Links::`) and inherit the domain application controller created in Plan 0. Keep `Admin::` only for platform-administration surfaces.
14. `Commercial::ResolveCharges` is the only producer of platform commission, service-fee, processing-recovery, subsidy, and resale-platform-fee calculation evidence. Orders persists its immutable results; payment providers merely receive projections. Do not add environment percentages, controller calculations, or a second resale fee engine.

## State-transition implementation standard

Use explicit commands and database state/timestamp constraints rather than a callback-heavy state-machine framework. The state diagrams in Section 15 of the database design are authoritative.

1. The model declares the allowed state values and query predicates; it does not perform cross-aggregate transitions in callbacks.
2. Each externally meaningful transition has one named command, such as `Events::Publish`, `Orders::AcceptPayment`, or `Ticketing::CredentialGenerations::Replace`.
3. The command locks the aggregate, returns the current record when the requested transition already completed with the same idempotency identity, rejects illegal source states with a typed `Core::BusinessError`, writes state plus coupled timestamps atomically, records audit evidence, and publishes outbox events in the same transaction.
4. Terminal states are irreversible unless the specification names an explicit compensating transition. Compensation appends new evidence; it never deletes or rewrites payment events, adjustments, refunds, ledger entries, credential generations, check-ins, admission uses, consents, or answer revisions.
5. Every transition receives a table-driven test covering each legal edge, every illegal edge, duplicate invocation, concurrent invocation, rollback, and outbox/audit behavior.
6. Add a state-machine gem only if the explicit transition matrix becomes demonstrably harder to understand or validate than the dependency. Do not add one merely to replace a small `case` statement.

## Test rules

- Write one failing behavior test before each production change and confirm the failure reason.
- Prefer `ActionDispatch::IntegrationTest` for endpoint workflows and real Active Record records/fixtures for domain behavior.
- Mock only external HTTP/KMS/storage/provider boundaries. Never mock commands, models, or Rails internals to make orchestration tests pass.
- Use separate database connections and `self.use_transactional_tests = false` for race tests; clean up in `ensure`.
- Freeze schedule, checkout, expiry, and payout time with `travel_to`.
- Every phase includes policy/visibility tests for public, buyer/holder, organization owner/admin/manager/staff/scanner, and platform-admin surfaces that exist in that phase.
- Every externally retryable command has a duplicate-request and crash-recovery test.
- Every asynchronous workflow has enqueue, perform, retry, idempotency, and reconciliation tests.

Use this command shape throughout:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/path/to/target_test.rb
```

Before every phase commit, run:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman --quiet --no-pager --exit-on-warn --exit-on-error
```

## Database-reset policy for this pre-launch project

This application is still in development. Do not build dual writes, compatibility columns, legacy serializers, temporary read fallbacks, or data translators for code that has never shipped.

- During an individual plan, create explicit migrations so the change is reviewable and testable.
- Before the first shared staging/production baseline, squash the new event-platform migrations into coherent domain migrations and reset development/test databases.
- Never edit a migration after any shared environment starts depending on it.
- Preserve existing Core/Organizations data only when the team explicitly needs it; otherwise use deterministic seeds after reset.
- The QR v1–v3.3 historical sketches are not an implementation source.

## Vertical release gates

### Gate A: Listing-only event

- Organization owner creates a private event, categories, settings, date, cover, and publishes it.
- Public discovery returns only public/published events.
- Direct private lookup requires authorization and never leaks through browse/search.

### Gate B: One free or paid ticket product

- Product has an immutable price/access snapshot and concurrency-safe capacity.
- Commercial resolution produces exactly one result per required fee component through event → organization → program → default precedence; explicit zero is distinguishable from failure.
- An organization/event grant cannot worsen organizer obligations, and an accepted paid order preserves the exact schedule/component/basis/payer/refund evidence.
- Free registration confirms without a payment row.
- Paid registration cannot confirm until one payment is accepted.

### Gate C: One online admission

- Fulfillment creates exactly one package, its slots, one group generation, and a signed credential.
- Online validator creates one admission use; a concurrent duplicate loses.
- Retry creates no duplicate package, credential, ledger, or message.

### Gate D: Multi-day/group/offline admission

- Group entry consumes every slot only for the current access/date.
- Scanner sync uses package/generation/credential revocations and idempotent uploads.
- QR, PNR, and phone/manual lookup feed the same validator.

### Gate E: Financial completion

- Cancellation/refund and organizer ledger reconcile exactly by currency.
- Commercial adjustments, provider split/application fees, provider actual costs, platform subsidy usage, and finance ledger postings reconcile without re-resolving historical rules.
- Refund remains `pending_funds` when liquidity is absent; entitlement is never reduced.
- Organizer payout cannot consume immature or disputed value.

### Gate F: Controlled resale

- Listing is whole-package and organizer-policy controlled.
- Buyer checkout revokes/suspends seller access before payment.
- Success produces one ownership change and new buyer generation; failure creates a newer seller generation.
- Seller funds remain unavailable until event completion plus buffer.

### Gate G: Launch readiness

- Full authorization/serializer privacy matrix passes.
- Provider/webhook/refund/payout reconciliation drills pass.
- 50K-attendee scanner snapshot/delta and event browse/query budgets pass.
- Restore, key rotation, scanner compromise, event cancellation, and payout-hold runbooks are exercised.

## Task 1: Establish a clean planning branch and baseline

**Files:**
- Read: `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`
- Read: `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`
- Read: every plan in this set
- Verify: current Git status and baseline tests

- [ ] **Step 1: Record the pre-existing worktree without changing it**

Run:

```bash
git status --short
```

Expected: every existing user change is visible before implementation begins.

- [ ] **Step 2: Create an isolated implementation worktree**

From a clean source checkout, after preserving the current documentation changes, run:

```bash
git worktree add ../digis_backend-event-platform -b codex/event-platform-foundation
cd ../digis_backend-event-platform
```

Do not run the command from a state where the uncommitted plan files would be left behind or lost. Copy or commit only the reviewed plan set into the isolated branch before implementation; never reset or discard the original worktree.

- [ ] **Step 3: Run the baseline suite**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman --quiet --no-pager --exit-on-warn --exit-on-error
```

Expected: zero test failures, zero style offenses, and zero Brakeman warnings. Record pre-existing failures as separate baseline issues; do not weaken new tests to hide them.

- [ ] **Step 4: Commit only the isolated baseline metadata if the workflow creates it**

```bash
git status --short
```

Expected: no product code change from baseline setup.

## Task 2: Execute plans in dependency order

**Files:**
- Modify: plan checkboxes as work completes
- Test: phase-specific paths named by each plan

- [ ] **Step 1: Complete Plan 0 and its full-suite gate**
- [ ] **Step 2: Complete Plans 1–4 and prove a paid/free order can reach an issuance-ready state**
- [ ] **Step 3: Complete Plans 5–6 and prove online plus offline first-scan-wins**
- [ ] **Step 4: Complete Plan 7 and prove refund/ledger/payout reconciliation**
- [ ] **Step 5: Complete Plan 8 and prove every AJ resale invariant**
- [ ] **Step 6: Complete Plan 9 and prove streaming/add-on/link boundaries**
- [ ] **Step 7: Complete Plan 10 and pass every launch gate**

Do not begin a dependent phase merely because its migrations exist. The dependency's behavior and acceptance gate must be green.

## Task 3: Final implementation audit

**Files:**
- Verify: `db/structure.sql`
- Verify: `app/`, `test/`, `config/`, `docs/`

- [ ] **Step 1: Prove schema coverage**

Compare every table and constraint in Sections 6–11 and 17 of the database design against `db/structure.sql` and any deferred-trigger SQL.

- [ ] **Step 2: Prove QR contract coverage**

Run the language-neutral scanner fixture suite against both the Rails reference validator and the scanner implementation.

- [ ] **Step 3: Prove no forbidden compatibility debt exists**

```bash
rg -n "legacy|dual.write|fallback.*old|v1|v2|v3\.3" app test config db
```

Expected: no event-platform compatibility implementation. Legitimate documentation or provider fallback wording must be reviewed manually.

- [ ] **Step 4: Run the entire CI contract**

```bash
PATH="$HOME/.asdf/shims:$PATH" bin/ci
```

Expected: setup, RuboCop, bundler audit, Brakeman, Rails tests, and seed replant all pass.

- [ ] **Step 5: Commit the completed release gate**

```bash
git add app config db lib test docs
git commit -m "feat(events): complete composable ticketing platform"
```

Expected: the commit contains only reviewed event-platform implementation and documentation.
