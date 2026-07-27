# Idempotency Assertions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable, pluggable idempotency assertion (`assert_idempotent` + `assert_audit_idempotent`) and fix `Core::Audit::Record#validate_replay!` so replay of audit-emitting operations is verifiably idempotent.

**Architecture:** A test-only concern in `test/support` exposes a generic counter-based `assert_idempotent(subject, counter:)` plus an audit-specific wrapper. A small production fix strips volatile timestamps from the replay comparison so a correctly-keyed retry does not raise `ReplayConflict`. The four audit-emitting operations (Configure, Reorder, Update, recurrence destroy) get idempotency tests.

**Tech Stack:** Rails 8 / Minitest / Mocha (`mocha/minitest`) / ActiveJob test helpers; existing `Core::Audit::Record` and `Core::AuditLog`.

> **Commit convention:** This project follows a no-auto-commit rule. The `Commit` steps below reflect the skill's frequent-commit guidance but MUST only be run after the user explicitly approves each commit.

---

## File Structure

- **Create (overwrites prototype):** `test/support/idempotency_assertions.rb` — the reusable helper, auto-loaded by `test/test_helper.rb` (`Dir[...test/support/**/*.rb]`), mixed into `ActiveSupport::TestCase`.
- **Modify:** `app/services/core/audit/record.rb` — strip volatile timestamps in `validate_replay!`.
- **Modify:** `test/services/events/recurrence/configure_test.rb` — replace the inline replay test with a helper-based one.
- **Modify:** `test/services/events/media/reorder_test.rb` — add a helper-based idempotency test.
- **Create:** `test/services/events/media/update_test.rb` — new file; idempotency test for `Events::Media::Update`.
- **Create:** `test/controllers/events/recurrence_rules_controller_test.rb` — new file; idempotency test for the destroy audit path.

---

### Task 1: Write the four idempotency tests (they fail initially)

**Files:**
- Modify: `test/services/events/recurrence/configure_test.rb`
- Modify: `test/services/events/media/reorder_test.rb`
- Create: `test/services/events/media/update_test.rb`
- Create: `test/controllers/events/recurrence_rules_controller_test.rb`

- [ ] **Step 1: Replace the inline replay test in `configure_test.rb`**

Find and replace this block:

```ruby
      test "replaying an identical configure does not duplicate the audit entry" do
        event = events_events(:ready_listing)
        assert_difference -> { Core::AuditLog.where(action: "event.recurrence.configured").count }, 1 do
          Events::Recurrence::Configure.call(event:, actor: core_users(:core_admin), attributes: valid_attributes)
          Events::Recurrence::Configure.call(event:, actor: core_users(:core_admin), attributes: valid_attributes)
        end
      end
```

with:

```ruby
      test "replaying an identical configure is idempotent with respect to the audit log" do
        event = events_events(:ready_listing)
        subject = lambda do
          Events::Recurrence::Configure.call(event:, actor: core_users(:core_admin), attributes: valid_attributes)
        end
        assert_audit_idempotent(
          subject,
          action: "event.recurrence.configured",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: -> { Events::RecurrenceRule.where(event:).first&.id }
        )
      end
```

- [ ] **Step 2: Add an idempotency test to `reorder_test.rb`**

Append inside the `Events::Media::ReorderTest` class:

```ruby
      test "reordering is idempotent with respect to the audit log" do
        subject = -> { Events::Media::Reorder.call(event: @event, actor: @user, ordered_ids: [ @c.id, @a.id, @b.id ]) }
        assert_audit_idempotent(
          subject,
          action: "event.media.reordered",
          auditable_type: "Events::Event",
          auditable_id: @event.id
        )
      end
```

- [ ] **Step 3: Create `test/services/events/media/update_test.rb`**

```ruby
# frozen_string_literal: true

require "test_helper"

module Events
  module Media
    class UpdateTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @user = core_users(:super_admin)
        @media = Events::EventMedia.create!(event: @event, created_by: @user, type: "gallery", position: 1) do |m|
          attach(m)
        end
      end

      def attach(media)
        media.file.attach(
          io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
          filename: "pixel.png", content_type: "image/png"
        )
      end

      test "updating media is idempotent with respect to the audit log" do
        attributes = { alt_text: "a cat", caption: "cute" }
        subject = -> { Events::Media::Update.call(media: @media, actor: @user, attributes: attributes, file: nil) }
        assert_audit_idempotent(
          subject,
          action: "event.media.updated",
          auditable_type: "Events::EventMedia",
          auditable_id: @media.id
        )
      end
    end
  end
end
```

- [ ] **Step 4: Create `test/controllers/events/recurrence_rules_controller_test.rb`**

```ruby
# frozen_string_literal: true

require "test_helper"

module Events
  class RecurrenceRulesControllerAuditTest < ActiveSupport::TestCase
    def setup
      @event = events_events(:ready_listing)
      @user = core_users(:core_admin)
      @rule = Events::RecurrenceRule.create!(
        event: @event,
        rrule: "FREQ=DAILY;COUNT=1",
        timezone: "Africa/Addis_Ababa",
        dtstart_local: Time.zone.local(2026, 8, 1, 20, 0, 0),
        duration_seconds: 3600
      )
    end

    test "destroy audit is idempotent with respect to the audit log" do
      controller = Events::RecurrenceRulesController.new
      controller.instance_variable_set(:@rule, @rule)
      controller.instance_variable_set(:@event, @event)
      subject = lambda do
        controller.stub(:current_user) { @user }
        controller.send(:record_audit)
      end
      assert_audit_idempotent(
        subject,
        action: "event.recurrence.removed",
        auditable_type: "Events::RecurrenceRule",
        auditable_id: @rule.id
      )
    end
  end
end
```

- [ ] **Step 5: Run the four new tests to confirm they FAIL (helper not defined)**

Run: `bin/rails test test/services/events/recurrence/configure_test.rb test/services/events/media/reorder_test.rb test/services/events/media/update_test.rb test/controllers/events/recurrence_rules_controller_test.rb`
Expected: failures/errors — `NoMethodError: undefined method 'assert_audit_idempotent'` (helper missing). This is the red state.

---

### Task 2: Implement the reusable helper

**Files:**
- Create (overwrites prototype): `test/support/idempotency_assertions.rb`

- [ ] **Step 1: Write the helper**

```ruby
# frozen_string_literal: true

# Reusable idempotency assertions for operations whose side effects must be
# stable under replay (retries, double-submits, at-least-once job delivery).
#
# The classic bug this catches: an operation claims to be idempotent (e.g. via
# a unique "idempotency key") but its key is non-deterministic, so a replay
# silently duplicates the side effect instead of collapsing onto it. A
# happy-path test that runs the operation once never exercises the replay path,
# which is exactly why this class of defect slips through.
module IdempotencyAssertions
  # `subject` - a callable performing the operation (invoked repeatedly).
  # `counter` - a callable returning an integer measure of the persistent side
  #             effect (e.g. the number of audit rows for an action).
  # `require_effect` - when true (default), the first run must actually change
  #             the counter; guards against trivially asserting a no-op is
  #             idempotent.
  #
  # The first run must have an effect, and every identical replay must leave
  # that measure unchanged.
  def assert_idempotent(subject, counter:, require_effect: true)
    baseline = counter.call
    subject.call
    first = counter.call

    if require_effect
      assert_operator first, :>, baseline,
        "operation had no observable persistent effect; nothing to assert idempotency against"
    end

    subject.call
    second = counter.call
    assert_equal first, second,
      "replaying an identical operation changed its persistent effect " \
      "(#{first} -> #{second}); the operation is not idempotent"
  end

  # Audit-system helper: asserts replaying `subject` does not create duplicate
  # Core::AuditLog rows for the same action/resource. `auditable_id` may be a
  # value or a callable (so it can be resolved after `subject` creates the row).
  def assert_audit_idempotent(subject, action:, auditable_type:, auditable_id:)
    resolve_id = auditable_id.respond_to?(:call) ? auditable_id : -> { auditable_id }
    counter = lambda do
      Core::AuditLog.where(action:, auditable_type:, auditable_id: resolve_id.call).count
    end
    assert_idempotent(subject, counter:)
  end
end

ActiveSupport::TestCase.include(IdempotencyAssertions)
```

- [ ] **Step 2: Run the four new tests**

Run: `bin/rails test test/services/events/recurrence/configure_test.rb test/services/events/media/reorder_test.rb test/services/events/media/update_test.rb test/controllers/events/recurrence_rules_controller_test.rb`
Expected: `reorder` and `recurrence destroy` PASS (deterministic keys, payloads without volatile drift). `configure` and `update` FAIL/ERROR with `Core::Audit::Record::ReplayConflict` — the recorder still raises on `updated_at` drift between replays. This is the incremental green state.

---

### Task 3: Fix `validate_replay!` to ignore volatile timestamps

**Files:**
- Modify: `app/services/core/audit/record.rb` (around line 97)

- [ ] **Step 1: Replace `validate_replay!` and add `strip_volatile`**

Find:

```ruby
      def validate_replay!(audit)
        expected = canonical(@attributes.stringify_keys.slice(*REPLAY_FIELDS))
        actual = canonical(audit.attributes.slice(*REPLAY_FIELDS))
        return if expected == actual

        fail ReplayConflict, "audit_key was already used for a different payload"
      end
```

Replace with:

```ruby
      def validate_replay!(audit)
        expected = canonical(strip_volatile(@attributes.stringify_keys.slice(*REPLAY_FIELDS)))
        actual = canonical(strip_volatile(audit.attributes.slice(*REPLAY_FIELDS)))
        return if expected == actual

        fail ReplayConflict, "audit_key was already used for a different payload"
      end

      VOLATILE_AUDIT_KEYS = %w[created_at updated_at].freeze

      # Timestamps drift on every save, so two otherwise-identical replays would
      # otherwise compare unequal and raise ReplayConflict. They are a side
      # effect of persisting, not part of the audited intent, so exclude them
      # from the replay-equality check.
      def strip_volatile(payload)
        payload = payload.dup
        payload["audited_changes"]&.except!(*VOLATILE_AUDIT_KEYS)
        payload
      end
```

- [ ] **Step 2: Run the four new tests**

Run: `bin/rails test test/services/events/recurrence/configure_test.rb test/services/events/media/reorder_test.rb test/services/events/media/update_test.rb test/controllers/events/recurrence_rules_controller_test.rb`
Expected: ALL PASS. `configure` and `update` now dedupe correctly because the recorder ignores `updated_at` drift.

---

### Task 4: Full verification

**Files:** (none changed — verification only)

- [ ] **Step 1: Run the full suite**

Run: `bin/rails test`
Expected: 0 failures, 0 errors (baseline was 950; the 4 new tests add to it).

- [ ] **Step 2: Run RuboCop and Brakeman**

Run: `bundle exec rubocop`
Expected: 0 offenses.
Run: `bundle exec brakeman --no-pager -q`
Expected: 0 warnings.

---

### Task 5: Commit (only after explicit user approval)

- [ ] **Step 1: Stage and commit the test helper, recorder fix, and tests**

```bash
git add test/support/idempotency_assertions.rb \
        app/services/core/audit/record.rb \
        test/services/events/recurrence/configure_test.rb \
        test/services/events/media/reorder_test.rb \
        test/services/events/media/update_test.rb \
        test/controllers/events/recurrence_rules_controller_test.rb
git commit -m "test: add reusable idempotency assertions and fix audit replay check"
```

> Do not run this until the user approves the commit.

---

## Notes / convention

- Any new command service that writes audit or claims idempotency should get one `assert_audit_idempotent` (or `assert_idempotent`) test.
- `media Create` / `Remove` are intentionally **not** covered by this helper: the effect-layer counter is scoped by `auditable_id`, so a duplicate-create would look stable and give a false pass. A separate command-layer helper (`assert_idempotent_resource`) is deferred — flag it whenever we add/modify a command that creates a resource or is reachable via an at-least-once path (HTTP retry, job redelivery, double-submit).
