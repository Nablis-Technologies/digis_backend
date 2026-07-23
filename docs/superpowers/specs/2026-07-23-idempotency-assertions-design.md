# Reusable Idempotency Assertions — Design

## Context / Problem

A class of bug keeps recurring in the event platform's audit path: an operation
that *claims* to be idempotent (via a unique `audit_key`) actually produces a
**duplicate side effect on replay**, because its key is non-deterministic or
collides. Two concrete instances were found and fixed:

- `Events::Recurrence::Configure`, `Events::Media::Reorder`, and
  `RecurrenceRulesController#destroy` used `SecureRandom.uuid` in the audit key,
  so a retried operation wrote a *second* `Core::AuditLog` row instead of
  collapsing onto the first.
- `Events::Media::Update` used `audit_key: "event-media-update-#{id}"`, which
  collides across distinct updates and raises `ReplayConflict` on the second
  update (different `audited_changes`).

Happy-path tests never catch these because they run the operation **once**;
the replay path (`RecordNotUnique` → `validate_replay!`) is never exercised.

## Goal

A single, reusable, **pluggable** assertion that proves an operation is stable
under replay, so this bug class is caught automatically wherever it is applied.

## Non-goals

- Command-layer (resource-duplication) idempotency — see "Trigger for future
  work" below. The effect-layer helper deliberately cannot catch duplicate
  creates, and we will not silently scope `Create`/`Remove` into it.
- Enforcing idempotency by tooling/convention — we document the convention,
  we do not build a registry/runner.

## Design

### 1. Location & wiring
- New file `test/support/idempotency_assertions.rb`.
- `test/test_helper.rb` already does
  `Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }`, so it is
  auto-loaded.
- At the bottom of the file: `ActiveSupport::TestCase.include(IdempotencyAssertions)`
  so every test class gets the helpers for free.

### 2. Generic helper (the pluggable core)
```ruby
assert_idempotent(subject, counter:, require_effect: true)
```
- `subject` — a callable performing the operation (invoked repeatedly).
- `counter` — a callable returning an integer measure of the *persistent* side
  effect (audit rows, created records, enqueued jobs, cache writes, …).
- Semantics:
  - `baseline = counter.call`
  - run `subject` → `first`; assert `first > baseline` **if** `require_effect`
    (guards against trivially asserting a no-op is idempotent).
  - run `subject` again → `second`; assert `second == first`.
- `require_effect: false` is available for operations that may legitimately be a
  no-op on first run (e.g. idempotent delete of an already-absent record).

This is the reusable primitive: any operation + any effect counter.

### 3. Audit-specific wrapper (thin convenience)
```ruby
assert_audit_idempotent(subject, action:, auditable_type:, auditable_id:)
```
- Builds `counter = -> { Core::AuditLog.where(action:, auditable_type:,
  auditable_id: resolve_id.call).count }`.
- `auditable_id` accepts a value **or a callable** (resolved lazily *after*
  `subject` runs, so it works for `Configure`, where the rule id does not exist
  at baseline).

### 4. Recorder fix (production code)
- In `Core::Audit::Record#validate_replay!` (app/services/core/audit/record.rb),
  strip `created_at` / `updated_at` from the `audited_changes` sub-hash before
  comparing (new private `strip_volatile`).
- Required so a *correctly-keyed* replay of `Configure`/`Update` actually
  succeeds instead of raising `ReplayConflict` on timestamp drift. Without this,
  the audit-idempotency tests for those operations cannot pass.

### 5. Initial adoption
Wire `assert_audit_idempotent` tests to the operations that are genuinely
replay-idempotent:
- `Events::Recurrence::Configure`
- `Events::Media::Reorder`
- `Events::Media::Update`
- `RecurrenceRulesController#destroy`

`media Create` / `Remove` are **out of scope** for this assertion (see Non-goals
and the future-work trigger).

### 6. What it catches vs. does not
- ✅ Non-deterministic keys (`SecureRandom.uuid`) → duplicate rows on replay.
- ✅ Key collisions on distinct updates → `ReplayConflict`.
- ✅ Timestamp-sensitive replay (the recorder bug) → fixed by §4.
- ❌ Command-layer non-idempotency (duplicate create) → needs a different,
  resource-identity assertion; intentionally not covered here.

### 7. Convention
- Recommend: any new command service that writes audit or claims idempotency
  gets one `assert_audit_idempotent` (or `assert_idempotent`) test.

## Trigger for future work: `assert_idempotent_resource`

When we **add or modify a command that creates a resource, or any command
reachable via an at-least-once path** (HTTP retry, ActiveJob redelivery,
double-submit / double-click), flag that we need the command-layer helper:

- `assert_idempotent_resource(subject, finder:)` — asserts replay returns the
  **same record** (same id), not a new one.
- Likely also requires the command to honor an idempotency key (Stripe-style
  short-circuit) so a retry returns the existing resource instead of creating a
  duplicate.

This is a separate, heavier concern. Do **not** scope `Create`/`Remove` into the
audit helper, because its counter is keyed by `auditable_id` and would falsely
report "idempotent" on a duplicate create.

## Verification
- All new/updated tests pass: `bin/rails test`.
- Full suite stays green (currently 950 tests); RuboCop and Brakeman clean.
- The `Configure` and `Update` idempotency tests would have failed against the
  original `SecureRandom` / colliding-key code, proving the helper's value.

## Status
- Design approved 2026-07-23.
- Prototype of `test/support/idempotency_assertions.rb` and the
  `validate_replay!` fix already exist from earlier exploration and will be
  reworked to match this spec during implementation.
