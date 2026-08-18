# Commercial Agreements and Platform Pricing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved, provider-independent Commercial module so Digis can apply platform defaults, reusable programs, organization/event grants, negotiated agreements, prospective volume tiers, and budgeted subsidies while every quote remains deterministic, explainable, auditable, and reproducible.

**Architecture:** `Commercial` is a top-level bounded context between Registration/Catalog and Orders. Immutable schedule versions contain allowlisted fee components; assignments select programs, grants, or mutual agreements; one resolver applies component-level precedence and returns frozen value objects. Commands own lifecycle transitions and synchronous audit/outbox evidence. Orders snapshots Commercial results as immutable adjustments, while Finance and Marketplace consume those results without creating competing fee engines.

**Tech Stack:** Rails 8.1, Ruby, PostgreSQL, Minitest, Pundit, ActiveModel Serializers, `Core::BaseService`, `Core::Audit::Record`, `Core::Outbox::Publish`, `Core::IdempotencyKeyResolver`, and the existing Legal, Organizations, Events, Catalog, Orders, Finance, and Marketplace boundaries.

---

## Normative sources and non-negotiable decisions

- `docs/superpowers/specs/2026-08-08-commercial-agreements-platform-pricing-design.md`
- `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`, especially Section 8A and Orders adjustments
- `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md`
- `docs/superpowers/plans/2026-07-17-orders-payments-implementation.md`
- `docs/superpowers/plans/2026-07-17-controlled-resale-marketplace-implementation.md`

Implementation must preserve these decisions:

1. This is an agreement system with allowlisted strategies, not a JSON/expression rules engine.
2. Resolution is per component: event assignment, organization assignment, assigned program, then platform default. An absent component inherits; an explicit zero overrides.
3. Grants may only improve the complete organizer baseline and need no organizer acceptance. Mutual agreements may alter obligations and require exact acceptance or an external contract reference.
4. Platform-default changes use `none`, `notice_only`, or `explicit` acceptance policy; negotiated increases are always explicit.
5. Fixed amounts, caps, gross tiers, and subsidy budgets are currency-specific. No runtime FX conversion is allowed inside Commercial.
6. Changes are prospective. Existing unexpired quotes and accepted orders retain their immutable snapshots.
7. Primary-sale and resale fees are distinct component types and never inherit from one another implicitly.
8. Runtime gaps or ambiguities fail closed. Only an explicit-zero component yields zero.
9. No arbitrary `type`/`kind` STI columns. Any business `type` column must use `self.inheritance_column = nil`; prefer descriptive names such as `schedule_type` and `component_type`.
10. One table per migration, UUIDv7 primary keys, explicit foreign keys, checks, and indexes.

## Implementation discipline

- Execute tasks in order. Do not begin Orders integration until the resolver contract and lifecycle tests are green.
- Use the domain-module generator before hand-editing each new model. Generate only `migration,model`; then replace the generated migration body and model behavior with the exact design below. Do not generate public CRUD for internal evidence tables.
- Each mutating HTTP command requires `Idempotency-Key` via `Core::IdempotencyKeyResolver` and proves replay behavior with `IdempotencyAssertions`.
- Financial/lifecycle commands write `Core::Audit::Record` and `Core::Outbox::Publish` synchronously inside the authoritative transaction.
- Run focused tests after every task and full Commercial tests at each checkpoint. Run RuboCop on changed Ruby files before committing.
- Never store legal bodies, internal negotiation prose, provider secrets, or arbitrary submitted JSON in audit/outbox/order evidence.

## Current implementation status and navigation (verified 2026-08-15)

The dependency-ordered Commercial tranche is complete through Task 12, the
final Commercial/Phase 3.5 reconciliation and operational gate. Orders Tasks
1–9 have passed their focused and full repository gates, and the integrated
Orders, Ticket Packages, Scanner, and Refunds/Finance Rails tranches are merged
into `main`. Controlled Resale Task 11 was committed in `b3ca5cb`. Streaming /
Add-ons / Links remains a separate Wave 6 track.

| Task | Status | Evidence / boundary |
|---|---|---|
| 1–6 | Complete | Namespace, governed definitions, assignments/legal evidence, resolver/calculators, lifecycle/acceptance, and first-event entitlement code plus tests are committed. |
| 7A | Complete | Per-currency subsidy budgets and database invariants are committed and tested. |
| 7B | Complete | Order-linked subsidy reservations now reference the real Orders schema and are committed/tested; the former placeholder-table gate is closed. |
| 8 | Complete | Volume counters/usages and event payer selections are committed/tested for the Orders handoff. |
| 9 | Complete | Admin/organizer API, privacy policies, serializers, routes, locales, tests, and Postman synchronization are implemented and verified. |
| 10 | Complete through the Orders Task 6 boundary | Orders checkout snapshots immutable Commercial results, the provider contract persists payment-attempt evidence, and sequential attempt start/switch behavior exists in Orders. Commercial owns the evidence contract; Orders owns payment orchestration. |
| 11 | Complete with Controlled Resale Task 3 | The Marketplace adapter consumes one immutable `resale_platform_fee` result with precedence, isolation, bounded specificity, evidence, and gross-cap tests. Listing/sale snapshot consumers remain in later Controlled Resale tasks; the Commercial/Task 3 handoff is committed. |
| 12 | Complete and merged | Reconciliation, shadow comparison, deduplicated audit/outbox operational alerts, scheduled expiry, recurring jobs, PostgreSQL verification, repeated entitlement/subsidy concurrency checks, full-suite verification, RuboCop, and Zeitwerk checks passed; the completed tranche is merged into `main`. |

### Current Commercial branch route

1. Commercial Tasks 1–12 are complete locally, including the final
   reconciliation, shadow comparison, operational-alert, scheduled-expiry,
   and Phase 3.5 gate. No further Commercial implementation task remains.
2. Review and commit the verified Orders, Ticket Packages, Scanner, and
   Refunds/Finance tranches. The native scanner SQLite acceptance row remains
   external and does not block the Rails dependency gate.
3. Refunds/Finance Tasks 1–10 and Controlled Resale Tasks 1–10 are now green and
   committed. Streaming/Add-ons/Links is a separate Wave 6 track and may run
   alongside Controlled Resale when ownership is explicit.
4. Commercial Task 11 and Controlled Resale Tasks 3–11 are committed. The
   Controlled Resale Task 11 locale correction is recorded in `b3ca5cb`; do not
   repeat that task.
5. Review and commit Commercial Task 12 after reviewing its final diff. Then
   return to the master roadmap for the next unresolved dependency phase.

The historical task recipes below remain the implementation specification for
each task. They are not a standalone execution queue; the route above and the
master roadmap determine when a task is eligible to start.

## Task 1: Establish the Commercial namespace and permissions

**Files:**

- Create: `app/models/commercial/application_record.rb`
- Create: `app/controllers/commercial/application_controller.rb`
- Create: `app/controllers/admin/commercial/application_controller.rb`
- Modify: `test/fixtures/core_permissions.yml`
- Modify: `test/fixtures/core_role_permissions.yml`
- Modify: `db/seeds.rb`
- Create: `test/models/commercial/namespace_test.rb`
- Create: `test/policies/commercial/commercial_authorization_test.rb`

- [x] **Step 1: Generate the namespace through the first aggregate skeleton**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module \
  Commercial::FeeSchedule name:string \
  --only=migration,model --no-interactive --no-auditable
```

Keep the generated namespace base class. The generated fee-schedule migration/model will be completed in Task 2.
Rename the generated migration to
`db/migrate/20260808090001_create_commercial_fee_schedules.rb` before any
database migration runs.

- [x] **Step 2: Write RED namespace and permission tests**

Assert:

- `Commercial::ApplicationRecord < Core::ApplicationRecord` and is abstract;
- `Commercial::ApplicationController < Core::ApplicationController`;
- the admin commercial controller inherits `Admin::ApplicationController`;
- non-super-admin access is permission-based, not generic `ADMIN` role-based;
- the following dedicated codes exist and are independently assignable:
  `commercial.view`, `commercial.draft`, `commercial.simulate`,
  `commercial.submit`, `commercial.approve`, `commercial.activate`,
  `commercial.grant`, `commercial.terminate`, `commercial.audit`,
  `commercial.budget_view`, and `commercial.break_glass`.

- [x] **Step 3: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/namespace_test.rb \
  test/policies/commercial/commercial_authorization_test.rb
```

Expected: failures for missing controller and permission fixtures/seeds.

- [x] **Step 4: Add namespace classes and permissions**

Use `Commercial::ApplicationRecord` for models. Admin policies must use the exact dedicated permission for each custom action and explicit `VISIBILITY`; super-admin remains an override through `Core::ApplicationPolicy`.

- [x] **Step 5: Run GREEN and lint**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/namespace_test.rb \
  test/policies/commercial/commercial_authorization_test.rb
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop \
  app/models/commercial app/controllers/commercial app/controllers/admin/commercial \
  test/models/commercial test/policies/commercial
```

- [x] **Step 6: Commit**

```bash
git add app/models/commercial app/controllers/commercial app/controllers/admin/commercial \
  test/fixtures/core_permissions.yml test/fixtures/core_role_permissions.yml db/seeds.rb \
  test/models/commercial test/policies/commercial
git commit -m "feat(commercial): establish module and permissions"
```

## Task 2: Implement immutable schedules, versions, components, currencies, and tiers

**Files:**

- Modify: `db/migrate/20260808090001_create_commercial_fee_schedules.rb`
- Create: `db/migrate/20260808090002_create_commercial_fee_schedule_versions.rb`
- Create: `db/migrate/20260808090003_create_commercial_fee_components.rb`
- Create: `db/migrate/20260808090004_create_commercial_fee_amounts.rb`
- Create: `db/migrate/20260808090005_create_commercial_fee_tiers.rb`
- Modify: `app/models/commercial/fee_schedule.rb`
- Create: `app/models/commercial/fee_schedule_version.rb`
- Create: `app/models/commercial/fee_component.rb`
- Create: `app/models/commercial/fee_amount.rb`
- Create: `app/models/commercial/fee_tier.rb`
- Create: `app/services/commercial/definitions/canonicalize.rb`
- Create: `app/services/commercial/definitions/validate.rb`
- Create: `test/models/commercial/fee_schedule_test.rb`
- Create: `test/models/commercial/fee_schedule_version_test.rb`
- Create: `test/models/commercial/fee_component_test.rb`
- Create: `test/models/commercial/fee_amount_test.rb`
- Create: `test/models/commercial/fee_tier_test.rb`
- Create: `test/services/commercial/definitions/canonicalize_test.rb`
- Create: `test/services/commercial/definitions/validate_test.rb`

- [x] **Step 1: Generate the remaining model/migration skeletons**

Run one generator per table:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::FeeScheduleVersion \
  status:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::FeeComponent \
  component_type:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::FeeAmount \
  currency:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::FeeTier \
  position:integer --only=migration,model --no-interactive --no-auditable
```

Rename generated timestamps to the canonical timestamps above before migrating. Confirm there is exactly one `create_table` per migration.

- [x] **Step 2: Write RED model and definition tests**

Prove all allowlists and shapes:

- schedule types: `platform_default`, `program`, `custom`; unique stable `code`;
- version states and ordered effective interval;
- definition immutability from `approved` onward;
- one positive version number per schedule and valid same-schedule supersession;
- component types: `platform_fee`, `service_fee`, `processing_fee`, `subsidy`, `resale_platform_fee`;
- calculations: `explicit_zero`, `percentage`, `fixed`, `blended`, `tiered`;
- payer/funder combinations, required basis, and component-specific refund policies;
- scope allowlists for sale context, product type, provider, payment method, channel, and currency;
- exact product scope only for a custom schedule whose assignment will target that product's event;
- amount currency normalization and ordered min/max;
- tiers start at zero, increase by threshold/position, and require currency only for gross metrics;
- canonical digest is order-independent for hashes/components but changes for any financially meaningful field;
- post-approval edits to nested components/amounts/tiers are rejected.

- [x] **Step 3: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/fee_schedule_test.rb \
  test/models/commercial/fee_schedule_version_test.rb \
  test/models/commercial/fee_component_test.rb \
  test/models/commercial/fee_amount_test.rb \
  test/models/commercial/fee_tier_test.rb \
  test/services/commercial/definitions
```

Expected: missing tables/models/services and constraint failures.

- [x] **Step 4: Implement migrations and database invariants**

The five tables must implement every column in design Sections 9.1–9.5. Add:

- UUIDv7 IDs and `on_delete: :restrict` FKs for historical definitions;
- unique schedule code and `(fee_schedule_id, version)`;
- self-FK for `supersedes_version_id`;
- published Legal version FK and all actor FKs;
- status/type/calculation/payer/funder/basis/refund checks;
- rate range `0..10_000` basis points; a percentage fee cannot exceed its complete basis;
- nonnegative monetary fields and ordered min/max checks;
- unique `(fee_component_id, currency)` and `(fee_component_id, position)`;
- searchable indexes on schedule/status/effective times and component scope columns;
- PostgreSQL exclusion constraint preventing overlapping authoritative intervals in a schedule for `scheduled`/`active` versions. Enable `btree_gist` only if not already enabled.

Cross-table definition shape, exact-product ownership, and equal-specificity ambiguity are enforced by `Commercial::Definitions::Validate` before simulation/activation; do not pretend a Rails validation alone is a concurrency guarantee.

- [x] **Step 5: Implement models and canonical definition services**

All models expose explicit associations, validations, scopes, `ransackable_attributes`, and `ransackable_associations`. `Canonicalize` emits an allowlisted, stable-key, stable-order representation and SHA-256 digest. `Validate` returns `Result.failure(Core::BusinessError)` with stable error codes for gaps, conflicts, invalid shapes, and missing currency coverage.

- [x] **Step 6: Reset the development/test schema and run GREEN**

Because the project is pre-production, edit the original generated migrations rather than adding corrective migrations.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/commercial test/services/commercial/definitions
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop app/models/commercial app/services/commercial test/models/commercial test/services/commercial
```

- [x] **Step 7: Commit**

```bash
git add db/migrate app/models/commercial app/services/commercial/definitions \
  test/models/commercial test/services/commercial/definitions db/structure.sql
git commit -m "feat(commercial): model immutable fee schedules"
```

## Task 3: Add programs, assignments, and exact legal evidence

**Files:**

- Create: `db/migrate/20260808090006_create_commercial_programs.rb`
- Create: `db/migrate/20260808090007_create_commercial_assignments.rb`
- Create: `app/models/commercial/program.rb`
- Create: `app/models/commercial/assignment.rb`
- Modify: `app/models/legal/legal_acceptance.rb`
- Modify: `app/services/legal/record_acceptance.rb`
- Create: `app/services/commercial/assignments/create_draft.rb`
- Create: `app/services/commercial/assignments/record_external_acceptance.rb`
- Create: `app/services/commercial/grants/validate_benefit.rb`
- Create: `test/models/commercial/program_test.rb`
- Create: `test/models/commercial/assignment_test.rb`
- Create: `test/services/commercial/assignments/create_draft_test.rb`
- Create: `test/services/commercial/assignments/record_external_acceptance_test.rb`
- Create: `test/services/commercial/grants/validate_benefit_test.rb`
- Modify: `test/models/legal/legal_acceptance_test.rb`
- Modify: `test/services/legal/record_acceptance_test.rb`

- [x] **Step 1: Generate one skeleton per new table**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::Program \
  program_type:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::Assignment \
  assignment_type:string --only=migration,model --no-interactive --no-auditable
```

Rename migration timestamps to the canonical names above.

- [x] **Step 2: Write RED tests**

Prove:

- one program belongs to one `program` schedule;
- program types use an allowlisted strategy registry, not JSON conditions;
- event-targeted assignments require the event to belong to the organization;
- assignment types/states/risk levels/effective intervals are constrained;
- a platform grant does not require acceptance but stores baseline digest and reason;
- a mutual agreement cannot schedule/activate without either exact in-app acceptance or a nonblank external reference;
- in-app acceptance links the exact published legal version referenced by the assigned schedule version;
- `Legal::LegalAcceptance` supports `commercial_assignment` as an allowlisted subject without generic constantization;
- external acceptance stores only a controlled reference, acceptance time, and actor—not uploaded contract contents;
- beneficial comparison detects rate increases, removed caps, payer switches, shorter benefits, removed subsidies, and new organizer-funded components.

- [x] **Step 3: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/program_test.rb \
  test/models/commercial/assignment_test.rb \
  test/services/commercial/assignments \
  test/services/commercial/grants \
  test/models/legal/legal_acceptance_test.rb \
  test/services/legal/record_acceptance_test.rb
```

- [x] **Step 4: Implement schema, models, and commands**

Implement all columns and invariants from design Sections 9.6–9.7. Use explicit `organization_id` plus optional `event_id`; never use a polymorphic commercial target. Add partial/covering indexes for active organization and event resolution. The assignment owns creator/approver/activator identity, baseline digest, reason, legal evidence, effective interval, and optimistic lock.

`ValidateBenefit` compares normalized full baseline and proposed result matrices at every supported context/currency boundary. It must fail closed when a comparison cannot be proven.

- [x] **Step 5: Run GREEN, migrate, and lint**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial test/services/commercial/assignments \
  test/services/commercial/grants test/models/legal test/services/legal
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop \
  app/models/commercial app/services/commercial app/models/legal app/services/legal \
  test/models/commercial test/services/commercial test/models/legal test/services/legal
```

- [x] **Step 6: Commit**

```bash
git add db/migrate app/models/commercial app/services/commercial \
  app/models/legal app/services/legal test db/structure.sql
git commit -m "feat(commercial): add programs grants and agreements"
```

## Task 4: Build deterministic component resolution and calculation

**Files:**

- Create: `app/services/commercial/resolve_charges.rb`
- Create: `app/services/commercial/resolution/context.rb`
- Create: `app/services/commercial/resolution/component_result.rb`
- Create: `app/services/commercial/resolution/charge_result.rb`
- Create: `app/services/commercial/resolution/candidate_query.rb`
- Create: `app/services/commercial/resolution/select_component.rb`
- Create: `app/services/commercial/calculations/base.rb`
- Create: `app/services/commercial/calculations/explicit_zero.rb`
- Create: `app/services/commercial/calculations/percentage.rb`
- Create: `app/services/commercial/calculations/fixed.rb`
- Create: `app/services/commercial/calculations/blended.rb`
- Create: `app/services/commercial/calculations/tiered.rb`
- Create: `test/services/commercial/resolve_charges_test.rb`
- Create: `test/services/commercial/resolution/select_component_test.rb`
- Create: `test/services/commercial/calculations/*_test.rb`

- [x] **Step 1: Write RED resolver contract tests**

Create a compact matrix proving:

- event assignment → organization assignment → assigned program → platform default precedence;
- inheritance happens per component, while explicit zero stops fallback;
- scope specificity is deterministic across exact product, product type, sale context, provider, payment method, channel, and currency;
- an equal-precedence/equal-specificity tie returns `ambiguous_commercial_terms`;
- missing components/currency coverage return `commercial_terms_unavailable`;
- primary and resale components remain isolated;
- organizer payer selection is honored only when permitted;
- output contains immutable IDs and an allowlisted explanation, not ActiveRecord objects or internal notes;
- output is deeply frozen and serializes deterministically;
- calculations use integers and half-up rounding, with fixed → percentage → clamp ordering for blended rules;
- basis values come only from allowlisted trusted inputs;
- 0%, min/max boundaries, large values, and every supported currency behave without floats.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/commercial/resolve_charges_test.rb \
  test/services/commercial/resolution \
  test/services/commercial/calculations
```

- [x] **Step 3: Implement immutable value objects and strategy registries**

`Resolution::Context` accepts server-owned IDs/codes plus integer subtotals and a fixed `quoted_at`. Reject unknown keys. `SelectComponent` sorts candidates by explicit precedence/specificity tuples and verifies a single winner. Calculator dispatch uses a constant allowlist; never call `constantize` on persisted/user input.

`ChargeResult` must expose:

- currency, quoted time, definition/overall signature;
- buyer fee total, organizer fee total, subsidy total;
- ordered component results;
- each component's schedule/version/component IDs, calculation, basis, rate/fixed/min/max, tier/window, payer, funder, refund policy, amount, and scope evidence.

- [x] **Step 4: Run GREEN and query-count test**

The resolver must preload candidate versions/components/amounts/tiers and must not perform one query per component.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/commercial/resolution \
  test/services/commercial/calculations test/services/commercial/resolve_charges_test.rb
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop app/services/commercial test/services/commercial
```

- [x] **Step 5: Commit**

```bash
git add app/services/commercial test/services/commercial
git commit -m "feat(commercial): resolve and calculate platform charges"
```

## Task 5: Add simulations, approvals, lifecycle commands, and default acceptance policy

**Files:**

- Create: `db/migrate/20260808090008_create_commercial_simulations.rb`
- Create: `db/migrate/20260808090009_create_commercial_approvals.rb`
- Create: `db/migrate/20260808090010_create_commercial_term_notices.rb`
- Create: `app/models/commercial/simulation.rb`
- Create: `app/models/commercial/approval.rb`
- Create: `app/models/commercial/term_notice.rb`
- Create: `app/services/commercial/simulations/run.rb`
- Create: `app/services/commercial/versions/submit.rb`
- Create: `app/services/commercial/versions/approve.rb`
- Create: `app/services/commercial/versions/schedule.rb`
- Create: `app/services/commercial/versions/activate.rb`
- Create: `app/services/commercial/versions/terminate.rb`
- Create: `app/services/commercial/assignments/submit.rb`
- Create: `app/services/commercial/assignments/approve.rb`
- Create: `app/services/commercial/assignments/activate.rb`
- Create: `app/services/commercial/assignments/terminate.rb`
- Create: `app/services/commercial/defaults/classify_change.rb`
- Create: `app/services/commercial/defaults/eligible_version.rb`
- Create: `app/services/commercial/defaults/deliver_term_notice.rb`
- Create: `test/models/commercial/simulation_test.rb`
- Create: `test/models/commercial/approval_test.rb`
- Create: `test/models/commercial/term_notice_test.rb`
- Create: `test/services/commercial/simulations/run_test.rb`
- Create: `test/services/commercial/versions/*_test.rb`
- Create: `test/services/commercial/assignments/*_test.rb`
- Create: `test/services/commercial/defaults/*_test.rb`

- [x] **Step 1: Generate table skeletons, then write RED tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::Simulation \
  passed:boolean --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::Approval \
  decision:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::TermNotice \
  status:string --only=migration,model --no-interactive --no-auditable
```

Rename migrations to the canonical timestamps. Tests must prove:

- simulation binds to current definition digest and normalized scenario digest;
- editing a draft invalidates prior simulation/approval;
- submission needs a passing current simulation;
- maker/checker separation for mutual, default, high-risk, and break-glass changes;
- low-risk beneficial grants can use one authorized finance actor;
- approved definitions are immutable;
- activation atomically supersedes the previous active version and publishes audit/outbox once;
- default changes classify as beneficial, neutral, or worsening;
- `none` is rejected for worsening changes;
- `notice_only` requires durable notice before effective time;
- the exact-version in-app notice is idempotent, auditable, visible to authorized organization members, and must be `delivered` before `notice_only` eligibility;
- `explicit` resolves the previously accepted version until acceptance or `grandfather_until`, then fails closed if no version is eligible;
- mutual increases require explicit evidence regardless of configured acceptance policy;
- break glass cannot bypass acceptance and emits a security event;
- all commands are idempotent and conflicting request fingerprints fail.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/simulation_test.rb test/models/commercial/approval_test.rb \
  test/services/commercial/simulations test/services/commercial/versions \
  test/services/commercial/assignments test/services/commercial/defaults
```

- [x] **Step 3: Implement evidence tables and commands**

Simulation stores only definition/scenario digests, normalized outputs/warnings, pass/fail, actor, and time. Approval is append-only with decision/reason/digest/actor/target. Use an explicit target type allowlist if the approval target is polymorphic. `Commercial::TermNotice` stores the exact organization, default version, published Legal version, delivery method/state, timestamps, and evidence digest. It is a durable Commercial terms inbox record, not a replacement for Messaging.

Every transition locks the target, rechecks state/digest/authorization preconditions, writes `Core::Audit::Record`, publishes a bounded `Core::Outbox::Publish` event, and commits once. Never enqueue the controller audit job for these transitions.

- [x] **Step 4: Run GREEN, migration tests, and lint**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/commercial test/services/commercial
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop app/models/commercial app/services/commercial test/models/commercial test/services/commercial
```

- [x] **Step 5: Commit**

```bash
git add db/migrate app/models/commercial app/services/commercial test/models/commercial \
  test/services/commercial db/structure.sql
git commit -m "feat(commercial): govern pricing lifecycle and approvals"
```

## Task 6: Implement first-event entitlements and safe event publication consumption

**Files:**

- Create: `db/migrate/20260808090011_create_commercial_program_entitlements.rb`
- Create: `app/models/commercial/program_entitlement.rb`
- Create: `app/services/commercial/entitlements/reconcile_first_event.rb`
- Create: `app/services/commercial/entitlements/consume.rb`
- Create: `app/services/commercial/entitlements/release.rb`
- Create: `app/jobs/commercial/handle_event_published_job.rb`
- Modify: outbox dispatch registration/configuration for `event.published`
- Create: `test/models/commercial/program_entitlement_test.rb`
- Create: `test/services/commercial/entitlements/reconcile_first_event_test.rb`
- Create: `test/services/commercial/entitlements/consume_test.rb`
- Create: `test/services/commercial/entitlements/release_test.rb`
- Create: `test/jobs/commercial/handle_event_published_job_test.rb`
- Modify: `test/services/events/publish_test.rb`

- [x] **Step 1: Generate skeleton and write RED tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::ProgramEntitlement \
  status:string --only=migration,model --no-interactive --no-auditable
```

Prove available → reserved → consumed/released/expired state/timestamp checks; unique program/organization entitlement; earliest `(published_at, event_id)` wins under concurrent or reversed outbox delivery; duplicate publication is idempotent; first accepted paid order consumes; event end/cancellation with no accepted paid order releases; cancellation after consumption does not restore.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/program_entitlement_test.rb \
  test/services/commercial/entitlements \
  test/jobs/commercial/handle_event_published_job_test.rb \
  test/services/events/publish_test.rb
```

- [x] **Step 3: Implement without an Events → Commercial dependency**

Do not modify `Events::Publish` to call Commercial. It already emits `event.published`. The Commercial handler and the future checkout reconciliation both call the same idempotent `ReconcileFirstEvent`, locking organization entitlements and comparing authoritative event publication timestamps.

- [x] **Step 4: Run GREEN and commit**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/program_entitlement_test.rb test/services/commercial/entitlements \
  test/jobs/commercial/handle_event_published_job_test.rb test/services/events/publish_test.rb
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop app/models/commercial app/services/commercial app/jobs/commercial test
git add db/migrate app/models/commercial app/services/commercial app/jobs/commercial test db/structure.sql
git commit -m "feat(commercial): reserve first event benefits safely"
```

## Task 7: Implement currency budgets and subsidy reservations

Task 7 is split at the Orders boundary. The budget is a Commercial-owned
invariant and can be introduced now. A reservation is an order-linked
checkout record, so its explicit `orders_orders` foreign key and the
hold/processing/commit/release commands must land only after the Orders
schema exists. This avoids both a temporary placeholder Orders table and a
reservation table whose referential integrity would be weakened.

The execution boundary is explicit: complete Orders Tasks 1–2 first, then
complete Task 7B and Task 8 before beginning Orders Task 3. Orders Task 3 and
Commercial Task 10 are then implemented as one checkout integration tranche.
Do not create a seed order or temporary table to bypass this dependency.

### Task 7A: Implement hard per-currency subsidy budgets

**Files:**

- Create: `db/migrate/20260808090012_create_commercial_subsidy_budgets.rb`
- Create: `app/models/commercial/subsidy_budget.rb`
- Modify: `app/models/commercial/assignment.rb`
- Modify: `app/models/commercial/fee_component.rb`
- Modify: `app/models/commercial/program.rb`
- Create: `test/models/commercial/subsidy_budget_test.rb`

- [x] **Step 1: Generate the budget skeleton and write RED tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::SubsidyBudget \
  currency:string --only=migration model --no-interactive --no-auditable
```

Tests prove XOR budget ownership (`assignment_id` or `program_id`), exact
owner fee-version/component alignment, platform-subsidy-only usage,
component/currency compatibility, positive limits, nonnegative counters,
`reserved + consumed <= limit`, database check constraints, unique owner /
component / currency budgets, and safe Ransack contracts.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/subsidy_budget_test.rb
```

- [x] **Step 3: Implement database-backed budget invariants**

Use UUIDv7, explicit restrictive foreign keys, partial unique indexes for
assignment-owned and program-owned budgets, and database checks for owner
XOR, currency shape, positive limits, nonnegative counters/lock version, and
the hard counter cap. The model mirrors those checks and documents that
`lock_version` is reserved for the later transactional reservation command;
no order-linked mutation service belongs in this subtask.

- [x] **Step 4: Run GREEN, migration tests, and lint**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/subsidy_budget_test.rb
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop \
  app/models/commercial/subsidy_budget.rb app/models/commercial/assignment.rb \
  app/models/commercial/fee_component.rb app/models/commercial/program.rb \
  test/models/commercial/subsidy_budget_test.rb
```

### Task 7B: Implement order-linked subsidy reservations after Orders Task 2

This boundary is now complete: `orders_orders` was created and verified by
Orders Task 2, then the reservation schema and transactional commands landed
before Orders Task 3. Keep the restrictive foreign key and do not introduce a
placeholder Orders table to change this ordering.

**Files:**

- Create: `db/migrate/20260811090005_create_commercial_subsidy_reservations.rb`
- Create: `app/models/commercial/subsidy_reservation.rb`
- Create: `app/services/commercial/subsidies/hold.rb`
- Create: `app/services/commercial/subsidies/mark_processing.rb`
- Create: `app/services/commercial/subsidies/commit.rb`
- Create: `app/services/commercial/subsidies/release.rb`
- Create: `app/services/commercial/subsidies/expire_holds.rb`
- Create: `test/models/commercial/subsidy_reservation_test.rb`
- Create: `test/services/commercial/subsidies/*_test.rb`

The reservation migration must own an explicit restrictive foreign key to
`orders_orders`. Tests and services will then prove state/timestamp coupling,
request-fingerprint conflicts, idempotent replay, expiration, deterministic
budget locking, and two concurrent last-unit holds yielding exactly one
success. Hold/commit/release will update budget counters and reservation state
in one transaction, record SHA-256 evidence, and retain terminal reservations.

## Task 8: Implement prospective volume tiers and event payer selections after Task 7B

**Status:** Complete after Orders Task 2 and Commercial Task 7B. The volume and
payer-selection contracts are available to the Orders Task 3 checkout tranche.

**Files:**

- Create: `db/migrate/20260811090006_create_commercial_volume_counters.rb`
- Create: `db/migrate/20260811090007_create_commercial_volume_usages.rb`
- Create: `db/migrate/20260811090008_create_commercial_event_payer_selections.rb`
- Create: `app/models/commercial/volume_counter.rb`
- Create: `app/models/commercial/volume_usage.rb`
- Create: `app/models/commercial/event_payer_selection.rb`
- Create: `app/services/commercial/volume/record_accepted_order.rb`
- Create: `app/services/commercial/volume/reconcile.rb`
- Create: `app/services/commercial/event_payer_selections/set.rb`
- Modify: `app/services/commercial/resolve_charges.rb`
- Create: `test/models/commercial/volume_counter_test.rb`
- Create: `test/models/commercial/volume_usage_test.rb`
- Create: `test/models/commercial/event_payer_selection_test.rb`
- Create: `test/services/commercial/volume/*_test.rb`
- Create: `test/services/commercial/event_payer_selections/set_test.rb`
- Modify: `test/services/commercial/resolve_charges_test.rb`

- [x] **Step 1: Generate skeletons and write RED tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::VolumeCounter \
  metric_type:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::VolumeUsage \
  metric_type:string --only=migration,model --no-interactive --no-auditable
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails generate domain_module Commercial::EventPayerSelection \
  charged_to:string --only=migration,model --no-interactive --no-auditable
```

Rename the migrations to the canonical timestamps above.

Prove all event/month/quarter/year/agreement-term window boundaries; gross metrics require matching currency; usages are immutable and unique per accepted order/component/window; counters never decrement for accepted activity; duplicate accepted-payment events do not double count; prospective threshold selection uses the counter value before this order; reconciliation detects/repairs cache drift from immutable usage; payer selection is only buyer/organizer, belongs to the event/component, and becomes invalid when current terms no longer permit choice.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/commercial/volume_counter_test.rb test/models/commercial/volume_usage_test.rb \
  test/models/commercial/event_payer_selection_test.rb \
  test/services/commercial/volume test/services/commercial/event_payer_selections \
  test/services/commercial/resolve_charges_test.rb
```

- [x] **Step 3: Implement and integrate**

Use immutable usage as truth and counter as a locked cache. Store exact window start/end, metric, currency, component, organization, optional event, accepted order, and value. Update resolver evidence with counter-before, selected tier, and window identity.

- [x] **Step 4: Run GREEN and commit**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/commercial test/services/commercial
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop app/models/commercial app/services/commercial test
git add db/migrate app/models/commercial app/services/commercial test db/structure.sql
git commit -m "feat(commercial): track prospective tiers and payer choice"
```

## Task 9: Deliver admin and organizer API/UX contracts

**Files:**

- Create: `app/controllers/admin/commercial/fee_schedules_controller.rb`
- Create: `app/controllers/admin/commercial/fee_schedule_versions_controller.rb`
- Create: `app/controllers/admin/commercial/programs_controller.rb`
- Create: `app/controllers/admin/commercial/assignments_controller.rb`
- Create: `app/controllers/admin/commercial/simulations_controller.rb`
- Create: `app/controllers/admin/commercial/subsidy_budgets_controller.rb`
- Create: `app/controllers/commercial/organization_terms_controller.rb`
- Create: `app/controllers/commercial/event_payer_selections_controller.rb`
- Create: `app/policies/admin/fee_schedule_policy.rb`
- Create: `app/policies/admin/fee_schedule_version_policy.rb`
- Create: `app/policies/admin/program_policy.rb`
- Create: `app/policies/admin/assignment_policy.rb`
- Create: `app/policies/admin/simulation_policy.rb`
- Create: `app/policies/admin/subsidy_budget_policy.rb`
- Create: `app/policies/commercial/organization_terms_policy.rb`
- Create: `app/policies/commercial/event_payer_selection_policy.rb`
- Create: `app/serializers/commercial/fee_schedule_serializer.rb`
- Create: `app/serializers/commercial/fee_schedule_version_serializer.rb`
- Create: `app/serializers/commercial/fee_component_serializer.rb`
- Create: `app/serializers/commercial/program_serializer.rb`
- Create: `app/serializers/commercial/assignment_serializer.rb`
- Create: `app/serializers/commercial/simulation_serializer.rb`
- Create: `app/serializers/commercial/subsidy_budget_serializer.rb`
- Create: `app/serializers/commercial/organization_terms_serializer.rb`
- Create: `app/serializers/commercial/event_payer_selection_serializer.rb`
- Create: `app/serializers/commercial/fee_amount_serializer.rb`
- Create: `app/serializers/commercial/fee_tier_serializer.rb`
- Create: `app/serializers/commercial/term_notice_serializer.rb`
- Create: `app/models/commercial/organization_terms.rb`
- Create: `app/services/commercial/admin/persist_record.rb`
- Create: `app/services/commercial/admin/upsert_version.rb`
- Create: `app/services/commercial/admin/create_assignment.rb`
- Create: `app/services/commercial/assignments/reject.rb`
- Create: `app/services/commercial/queries/organization_terms.rb`
- Create: `app/services/commercial/versions/reject.rb`
- Modify: `config/routes.rb`
- Modify: `config/locales/commercial/governance.en.yml`
- Create: `test/integration/admin/commercial/fee_schedules_test.rb`
- Create: `test/integration/admin/commercial/fee_schedule_versions_test.rb`
- Create: `test/integration/admin/commercial/programs_test.rb`
- Create: `test/integration/admin/commercial/assignments_test.rb`
- Create: `test/integration/admin/commercial/simulations_test.rb`
- Create: `test/integration/admin/commercial/subsidy_budgets_test.rb`
- Create: `test/integration/commercial/organization_terms_test.rb`
- Create: `test/integration/commercial/event_payer_selections_test.rb`
- Modify: `postman/Digis API_collection.json`

- [x] **Step 1: Write RED policy and integration tests**

Test the full permission matrix and serializer privacy:

- platform admins see definitions according to dedicated permissions;
- maker cannot self-approve when separation is required;
- organizers see applicable current/scheduled terms, plain-language examples, legal links, acceptance history, and event exceptions;
- organizers never see internal reasons, approval discussion, risk flags, budget owner internals, provider contract costs, or margin/shadow analysis;
- public/buyer endpoints never expose organizer commissions or subsidies;
- organizer writes are limited to event payer selection;
- all mutations reject a missing `Idempotency-Key` with `missing_idempotency_key` and replay safely;
- no public arbitrary commercial-rule CRUD exists.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/policies/commercial test/integration/admin/commercial test/integration/commercial
```

- [x] **Step 3: Implement controllers/policies/serializers/routes**

Controllers normalize params, authorize, call one command/query, and render via `Core::CommandResponse`/`Core::JsonResponse`. Do not use controller callbacks as the authoritative audit for financial transitions. Add root-level routes consistent with the repository; do not introduce `/api/v1`.

Admin flow endpoints must support draft, simulate, submit, approve/reject, schedule/activate, terminate, and inspect. Organizer endpoints are read-only terms/explanation plus payer selection. The returned representation should directly support the approved grant/agreement wizard and organizer Commercial Terms page.

- [x] **Step 4: Update Postman in the same change**

Add positive, forbidden, missing-key, and replay examples. Keep request bodies aligned with allowlisted fields; never publish internal-only response examples in organizer folders.

- [x] **Step 5: Run GREEN and lint**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/policies/commercial test/integration/admin/commercial test/integration/commercial
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop \
  app/controllers/admin/commercial app/controllers/commercial app/policies app/serializers/commercial test
```

- [x] **Step 6: Commit**

```bash
git add app/controllers app/policies app/serializers config/routes.rb config/locales \
  test/integration test/policies postman/Digis\ API_collection.json
git commit -m "feat(commercial): expose governed pricing workflows"
```

## Task 10: Integrate immutable Commercial results into Orders and provider selection

**Current boundary:** The Commercial-owned projection and provider contract are
complete. Orders quotes and checkout carry immutable
`Commercial::Resolution::ChargeResult` evidence, project exact adjustment
rows, and expose a deterministic signature over the resolved Commercial
evidence and charge currency. Orders Task 5 now persists payment-attempt
snapshots, canonical provider results, durable provider-event identity, and
the injectable adapter registry. Provider and payment-method changes alone do
not change the signature; changed Commercial evidence does. Actual attempt
start/switch orchestration remains Orders Task 6. Do not move that orchestration
into Commercial or recalculate fees in a provider adapter.

**Execution split:** The historical checklist below spans the interleaved
Commercial/Orders work. The projection portion landed with Orders Task 3; the
payment-attempt schema and provider contract landed with Orders Task 5; and
attempt creation/switching, including provider calls, is intentionally tracked
as Orders Task 6. Use the Orders plan as the execution checklist for those
boundaries.

**Prerequisite:** Begin only after Orders Tasks 1–2 and Commercial Tasks 7B–8
exist. Execute this task together with Orders Task 3 and its checkout race
tests. If Orders is not yet implemented, stop after defining and
contract-testing `Commercial::ChargeResult`; resume this task during the
Orders Task 3 integration tranche.

**Files:**

- Modify: `db/migrate/20260811090001_create_orders.rb` (the original migration only)
- Modify: `db/migrate/20260811090003_create_order_adjustments.rb` (the original migration only)
- Modify: `app/models/orders/order.rb`
- Modify: `app/models/orders/order_adjustment.rb`
- Modify: `app/services/orders/create_checkout.rb`
- Modify: `app/services/orders/start_payment_attempt.rb`
- Create: `app/services/orders/commercial_adjustment_writer.rb`
- Create: `app/services/orders/commercial_signature.rb`
- Modify: `app/services/payments/providers/adapter.rb`
- Modify: `app/services/payments/providers/registry.rb`
- Modify: `app/services/payments/providers/result.rb`
- Modify: `app/services/payments/providers/chapa_adapter.rb`
- Modify: `test/models/orders/order_test.rb`
- Modify: `test/models/orders/order_adjustment_test.rb`
- Modify: `test/services/orders/create_checkout_test.rb`
- Modify: `test/services/orders/start_payment_attempt_test.rb`
- Create: `test/services/orders/commercial_adjustment_writer_test.rb`
- Modify: `test/services/payments/providers/chapa_adapter_test.rb`
- Modify: `test/integration/orders/checkout_concurrency_test.rb`

- [x] **Step 1: Write RED integration contract tests**

Prove:

- checkout consumes a fixed `Commercial::ChargeResult` and writes one immutable adjustment per result component;
- adjustment types include `subsidy` and `resale_platform_fee` and snapshot exact version/component, basis, calculation, payer, funder, rates/amounts/caps/tier/window/refund policy, and allowlisted explanation;
- order formula is `subtotal - discount - subsidy + fee + tax + adjustment`;
- order totals reconcile exactly to adjustment rows;
- existing quote remains unchanged after schedule activation;
- first-event reconciliation runs synchronously before benefit resolution;
- inventory, promotion, purchase-limit, volume, and subsidy locks follow the documented global order;
- subsidy reservations hold with checkout, move to processing/payment, commit on accepted payment, and release on expiry/failure;
- compatible provider/method retries reuse the order when the immutable Commercial signature matches; changed Commercial evidence returns `commercial_requote_required` and creates no payment attempt;
- no provider adapter recalculates a fee;
- accepted order records tier usage and consumes applicable entitlement exactly once.

- [x] **Step 2: Run RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/models/orders/order_test.rb test/models/orders/order_adjustment_test.rb \
  test/services/orders/create_checkout_test.rb \
  test/services/orders/start_payment_attempt_test.rb \
  test/services/orders/commercial_adjustment_writer_test.rb
```

- [x] **Step 3: Evolve original migrations and implement projection**

Because the project is not live, edit the original Orders migrations. Add `subsidy_minor` and exact commercial evidence/checks; do not add an alter-table cleanup migration. `CommercialAdjustmentWriter` accepts only the immutable value object, never active schedule records. Provider adapters translate stored results into provider instructions where supported and persist the projection/response separately.

- [x] **Step 4: Run GREEN plus end-to-end checkout tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate:reset
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/orders test/models/orders test/integration/orders \
  test/services/commercial
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop app/models/orders app/services/orders test
```

- [x] **Step 5: Commit**

```bash
git add db/migrate app/models/orders app/services/orders test db/structure.sql
git commit -m "feat(orders): snapshot resolved commercial charges"
```

## Task 11: Integrate the distinct resale commercial component

**Prerequisite:** Execute with the resale marketplace implementation plan.

**Execution boundary:** Commercial Task 11 is executed with Controlled Resale
Marketplace Task 3. It creates only the narrow adapter and its contract tests;
listing activation, resale checkout, and immutable listing/sale snapshot
consumers remain in the later Controlled Resale tasks. Marketplace does not
create a fee configuration table or a competing calculator.

**Files:**

- Create: `app/services/marketplace/resolve_resale_charge.rb`
- Create: `config/locales/marketplace/resale_fee.en.yml`
- Create: `test/support/marketplace/commercial_resale_test_helpers.rb`
- Create: `test/services/marketplace/commercial_resale_fee_test.rb`
- Create: `test/integration/marketplace/resale_fee_isolation_test.rb`

- [x] **Step 1: Write RED marketplace contract tests**

The tests cover event → organization → program → default precedence, primary
commission isolation, bounded product/currency/provider/channel specificity,
no stacking, exact immutable component/version evidence, seller fee gross
caps, and separate buyer service/processing adjustments.

- [x] **Step 2: Run RED**

The focused command reached the intended RED state after the shared helper was
corrected: 5 tests, 0 assertions, and 5 `NameError` errors for the missing
adapter.

- [x] **Step 3: Implement the narrow adapter**

`Marketplace::ResolveResaleCharge` forces the trusted gross into Commercial's
`resale_acquisition_amount` basis, passes `sale_context: resale` and
`sales_channel: resale`, requires one evidenced `resale_platform_fee`, fails
closed when the fee exceeds gross or terms are unavailable, and returns the
unchanged immutable Commercial result.

- [x] **Step 4: Run GREEN and regression verification**

Focused Task 3 coverage passes with `N_PLUS_ONE=1`: 7 tests and 45 assertions.
Marketplace and Commercial regression coverage passes with `N_PLUS_ONE=1`:
162 tests and 1,253 assertions. Full RuboCop passes for 1,329 files.

- [x] **Step 5: Commit**

The Commercial Task 11/Controlled Resale Task 3 handoff was committed in
`58f3718`; Controlled Resale Tasks 9–10 are committed. Controlled Resale Task
11's only implementation correction in this gate moved resale ledger
descriptions out of the `errors` locale namespace so the existing services
resolve their translation keys correctly. Task 11 was subsequently committed
in `b3ca5cb`, after which the final Commercial Task 12 gate was implemented and
verified below.

## Task 12: Add reconciliation, shadow comparison, operations alerts, and phase gate

**Files:**

- Create: `app/services/commercial/reconciliation/run.rb`
- Create: `app/services/commercial/shadow/compare.rb`
- Create: `app/jobs/commercial/reconciliation_job.rb`
- Create: `app/jobs/commercial/shadow_comparison_job.rb`
- Create: `app/jobs/commercial/expire_scheduled_state_job.rb`
- Create: `app/services/commercial/alerts/publish.rb`
- Create: `test/services/commercial/reconciliation/run_test.rb`
- Create: `test/services/commercial/shadow/compare_test.rb`
- Create: `test/jobs/commercial/*_test.rb`
- Modify: `config/recurring.yml`
- Modify: `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md` only to check off the phase after all gates pass

- [x] **Step 1: Write RED operational tests**

Prove reconciliation compares immutable order adjustments, subsidy usage, volume usage/counters, provider projections/actual costs when present, and later Finance ledger/payout allocations without rewriting history. Prove shadow mode runs proposed definitions against production-shaped contexts without changing checkout. Prove gaps, ambiguities, expiring explicit-acceptance grandfather periods, budget exhaustion, margin variance, and provider projection mismatches emit deduplicated operational events.

The Task 12 service and job tests pass as 10 tests with 67 assertions.

- [x] **Step 2: Run RED, then implement append-only correction behavior**

Corrections create new audit/reconciliation evidence or domain-specific reversal records; they never edit paid orders, accepted usages, or terminal reservations. Scheduled expiry/termination commands are idempotent and use the same lifecycle services as admin actions.

The implementation repairs only the prospective `VolumeCounter` cache from
immutable `VolumeUsage` evidence. Paid orders, order adjustments, accepted
payments, terminal subsidy reservations, finance ledger entries, and payout
allocations remain unchanged.

- [x] **Step 3: Run the complete phase verification**

```bash
PATH="$HOME/.asdf/shims:$PATH" RAILS_ENV=test bundle exec rails db:migrate:reset
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/commercial test/services/commercial \
  test/jobs/commercial test/policies/commercial test/integration/admin/commercial \
  test/integration/commercial test/services/legal test/services/events/publish_test.rb
RUBOCOP_CACHE_ROOT=tmp/rubocop bundle exec rubocop
git diff --check
```

When Orders and Marketplace prerequisite phases exist, also run their complete model/service/integration suites and the checkout concurrency tests.

The phase verification passed with 271 tests and 1,795 assertions. The
N+1-enabled repository suite then passed with 2,599 tests and 10,688
assertions. RuboCop reported no offenses across 1,411 files, Zeitwerk reported
`All is good!`, PostgreSQL migrations were reset successfully, and
`git diff --check` is clean.

- [x] **Step 4: Verify the approved UX contract**

Using Postman or the local client, demonstrate:

1. Create a platform default and publish its exact legal terms.
2. Simulate, approve, schedule, and activate it with distinct actors.
3. Grant an event-specific charity waiver without organizer acceptance and show the audit reason.
4. Create a negotiated organization agreement, capture external or in-app acceptance, and activate it.
5. Show inherited versus overridden components and an explicit 0% fee.
6. Reserve/consume/release first-event and subsidy benefits.
7. Show organizer current/scheduled terms without internal economics.
8. Resolve the same quote twice identically; demonstrate a fail-closed ambiguity.
9. If Orders exists, show immutable adjustments and provider-signature retry behavior.

Task 12 adds no endpoint, serializer, model, migration, seed, or Postman
contract, so there is no new client request to add or manually exercise. The
existing administrative, organizer, checkout, payment, and privacy contracts
were re-exercised by the full integration suite; the Task 12-only behavior is
covered by the service and job tests above.

- [x] **Step 5: Complete the phase gate**

Do not mark Phase 3.5 complete until:

- the verification matrix in design Section 19 is represented by tests;
- database constraints were exercised against PostgreSQL, not only model validations;
- concurrent entitlement/subsidy tests pass repeatedly;
- no controller or provider contains fee math;
- no Marketplace fee-config table/model exists;
- all Commercial mutations have idempotency, synchronous audit, and outbox evidence;
- serializers pass privacy tests for super-admin, delegated commercial roles, organizer owner/admin, event staff, buyer, and anonymous access;
- Postman matches routes and payloads;
- full tests and RuboCop are green.

The three-run PostgreSQL concurrency gate for entitlement consumption, earliest
event reconciliation, and final-unit subsidy holds passed 18 tests and 97
assertions on each run. No controller or provider fee math, Marketplace fee
configuration model, or new API surface was introduced. Existing Commercial
privacy, idempotency, audit, outbox, route, serializer, and Postman checks
remain green in the full suite.

- [x] **Step 6: Commit** — merged into `main` with the Commercial branch

```bash
git add app/services/commercial app/jobs/commercial test config docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md
git commit -m "feat(commercial): add reconciliation and operational safeguards"
```

The implementation is complete and the reviewed Task 12 tranche is merged
into `main`; the command above is retained as historical evidence only.

## Final implementation handoff

Task 12 completion evidence (2026-08-15):

- Added the reconciliation, shadow comparison, operational-alert, scheduled
  expiry, and recurring-job services listed above; no model or migration was
  needed because existing `Core::AuditLog` and `Core::OutboxEvent` provide the
  durable operational evidence boundary.
- Focused Task 12 tests pass with 10 tests and 67 assertions. The phase suite
  passes with 271 tests and 1,795 assertions. The full N+1-enabled suite passes
  with 2,599 tests and 10,688 assertions.
- The repeated concurrency gate passes three times with 18 tests and 97
  assertions per run. PostgreSQL reset, RuboCop, Zeitwerk, YAML parsing, route
  loading, and `git diff --check` all pass.
- Existing Commercial allowlists, seeded platform-default/legal IDs, and API
  payloads are unchanged; no seeds or Postman requests were applicable.
- No new dependency was introduced. The services consume existing Orders,
  Finance, Commercial, and Core evidence and deliberately leave any future
  alert dashboard/notification UI to a later operational follow-up.
- Rollback is limited to disabling recurring schedules or superseding/
  terminating Commercial versions. Historical audits, outbox events, paid
  orders, accepted usages, ledger entries, and payout allocations are never
  deleted or rewritten.

At completion, record:

- migration/model/service/controller/policy/serializer files added;
- exact test commands and results;
- concurrency test evidence;
- supported component/calculation/basis/refund/program allowlists;
- configured platform default and legal version IDs used in seed data;
- remaining dependencies on Orders, Finance, Marketplace, or Notifications;
- any intentionally deferred admin UI beyond the API contract;
- rollback strategy limited to disabling/superseding schedules, never deleting historical evidence.

The next phase may rely on `Commercial::ResolveCharges` only after its value-object schema, signature behavior, fail-closed errors, and immutable evidence tests are frozen.
