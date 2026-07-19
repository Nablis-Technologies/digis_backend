# Event Platform Core Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the small shared Rails primitives required by every event-platform phase without creating a generic framework that obscures domain behavior.

**Architecture:** Preserve `Core::BaseService`, `Core::Common`, `Core::JsonResponse`, Pundit, ActiveModelSerializers, and the existing domain generator. Add only proven cross-domain seams: typed business failures, command-result rendering, integer money, transaction-scoped advisory locks, a transactional outbox, one audit recorder with automatic asynchronous CRUD and synchronous transactional command entry points, encryption configuration, and namespace base classes. Complex writes remain explicit domain commands rather than being pushed into `Core::Common` or callbacks.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL, Active Record Encryption, Solid Queue, Pundit, ActiveModelSerializers, Minitest.

---

**Normative specifications:** `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md` and `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`. This plan supplies shared implementation primitives; it does not override either domain contract.

## Reuse and refactor decisions

| Existing seam | Decision | Reason |
|---|---|---|
| `Core::BaseService` | Extend in place | Already provides `.call` and `Result`; a second command framework would be debt |
| `Core::Common` | Reuse only for conventional CRUD | Its generic create/update transaction cannot express multi-aggregate locks and external lifecycle state |
| `Core::JsonResponse` | Add one `render_service_result` helper concern | Three or more command controllers need identical typed failure rendering |
| `Core::ApplicationPolicy` | Reuse and extend concrete policies | Permission and visibility intersection is already the authenticated response boundary |
| `Core::PublicCommon` | Reuse only for read-only public lists/details | Public serializers, not Pundit, are the security boundary |
| `Core::AuditableController` / `AuditLoggerJob` | **Preserve** the `auditable` DSL as controller-layer sugar; converge both it and the job onto `Core::Audit::Record` | Critical financial/ticket audit evidence must be written in the authoritative transaction, while CRUD audits keep the easy DSL |
| Domain-module generator | Add `--business-type` support | Many approved tables use a business `type` column and must disable STI consistently |
| Generic idempotency registry | Do not add | Aggregate-specific unique keys are safer; only key normalization is shared |

## Task 1: Add typed business failures and strengthen service results

**Files:**
- Create: `app/errors/core/business_error.rb`
- Modify: `app/services/core/base_service.rb`
- Create: `test/services/core/base_service_test.rb`
- Create: `test/errors/core/business_error_test.rb`

- [ ] **Step 1: Write the failing business-error tests**

```ruby
require "test_helper"

class Core::BusinessErrorTest < ActiveSupport::TestCase
  test "exposes stable API failure fields" do
    error = Core::BusinessError.new(
      "Inventory is no longer available",
      code: "inventory_unavailable",
      status: :conflict,
      errors: { quantity: ["exceeds availability"] },
      meta: { retryable: false }
    )

    assert_equal "inventory_unavailable", error.code
    assert_equal :conflict, error.status
    assert_equal({ quantity: ["exceeds availability"] }, error.errors)
    assert_equal({ retryable: false }, error.meta)
  end
end
```

```ruby
require "test_helper"

class Core::BaseServiceTest < ActiveSupport::TestCase
  class SuccessfulCommand < Core::BaseService
    def call = success(value: 42)
  end

  class RejectedCommand < Core::BaseService
    def call
      failure Core::BusinessError.new("No", code: "rejected", status: :conflict)
    end
  end

  test ".call returns a successful result" do
    result = SuccessfulCommand.call

    assert result.success?
    assert_equal({ value: 42 }, result.value)
  end

  test "failure preserves the typed error" do
    result = RejectedCommand.call

    assert result.failure?
    assert_instance_of Core::BusinessError, result.error
    assert_equal "rejected", result.error.code
  end
end
```

- [ ] **Step 2: Run the tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/errors/core/business_error_test.rb test/services/core/base_service_test.rb
```

Expected: errors because `Core::BusinessError`, `success`, and `failure` are not defined.

- [ ] **Step 3: Implement the typed error and service helpers**

```ruby
# frozen_string_literal: true

module Core
  class BusinessError < Core::Error
    attr_reader :code, :status, :errors, :meta

    def initialize(message, code:, status:, errors: nil, meta: nil)
      super(message)
      @code = code.to_s
      @status = status
      @errors = errors
      @meta = meta
    end

    def status_code = status
  end
end
```

Add these protected helpers to `Core::BaseService` without changing `.call` or `Result` readers:

```ruby
protected

def success(value = nil)
  Result.success(value)
end

def failure(error)
  fail ArgumentError, "failure requires a Core::Error" unless error.is_a?(Core::Error)

  Result.failure(error)
end
```

- [ ] **Step 4: Run the tests and verify GREEN**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/errors/core/business_error_test.rb test/services/core/base_service_test.rb
```

Expected: 3 tests, 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/errors/core/business_error.rb app/services/core/base_service.rb test/errors/core/business_error_test.rb test/services/core/base_service_test.rb
git commit -m "refactor(core): add typed service failures"
```

## Task 2: Render command results consistently

**Files:**
- Create: `app/controllers/concerns/core/command_response.rb`
- Modify: `app/controllers/core/application_controller.rb`
- Create: `test/controllers/concerns/core/command_response_test.rb`

- [ ] **Step 1: Write a failing concern test through a real controller**

```ruby
require "test_helper"

class CommandResponseProbeController < Core::ApplicationController
  skip_before_action :authenticate_user
  skip_authorization

  def success
    render_service_result Core::BaseService::Result.success({ id: "result-id" }), success_status: :created
  end

  def failure
    error = Core::BusinessError.new("Unavailable", code: "unavailable", status: :conflict)
    render_service_result Core::BaseService::Result.failure(error)
  end
end

class Core::CommandResponseTest < ActionController::TestCase
  tests CommandResponseProbeController

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "success", to: "command_response_probe#success"
      get "failure", to: "command_response_probe#failure"
    end
  end

  test "renders a successful command value" do
    get :success

    assert_response :created
    assert_equal true, response.parsed_body.fetch("success")
    assert_equal "result-id", response.parsed_body.dig("data", "id")
  end

  test "renders the typed failure status and code" do
    get :failure

    assert_response :conflict
    assert_equal false, response.parsed_body.fetch("success")
    assert_equal "unavailable", response.parsed_body.fetch("code")
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/concerns/core/command_response_test.rb
```

Expected: failure because `render_service_result` is missing.

- [ ] **Step 3: Implement the concern**

```ruby
# frozen_string_literal: true

module Core
  module CommandResponse
    extend ActiveSupport::Concern

    def render_service_result(result, success_status: :ok, serializer_options: {})
      return render_success(data: result.value, status: success_status, serializer_options:) if result.success?

      render_business_error(result.error)
    end

    private

    def render_business_error(error)
      render_error(
        error.message,
        status: error.status,
        code: error.code,
        errors: error.errors,
        meta: error.meta
      )
    end
  end
end
```

Include `Core::CommandResponse` in `Core::ApplicationController` after `Core::JsonResponse`.

- [ ] **Step 4: Run concern and authentication integration tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/controllers/concerns/core/command_response_test.rb test/integration/core/auth_test.rb
```

Expected: all tests pass; existing authentication response shape is unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/concerns/core/command_response.rb app/controllers/core/application_controller.rb test/controllers/concerns/core/command_response_test.rb
git commit -m "refactor(core): standardize command responses"
```

## Task 3: Add immutable money and idempotency-key value objects

**Files:**
- Create: `app/lib/core/money.rb`
- Create: `app/lib/core/idempotency_key.rb`
- Create: `test/lib/core/money_test.rb`
- Create: `test/lib/core/idempotency_key_test.rb`

- [ ] **Step 1: Write failing value-object tests**

```ruby
require "test_helper"

class Core::MoneyTest < ActiveSupport::TestCase
  test "adds only matching currencies" do
    total = Core::Money.new(amount_minor: 125, currency: "etb") +
      Core::Money.new(amount_minor: 75, currency: "ETB")

    assert_equal 200, total.amount_minor
    assert_equal "ETB", total.currency
  end

  test "rejects cross-currency arithmetic" do
    error = assert_raises(Core::Money::CurrencyMismatch) do
      Core::Money.new(amount_minor: 100, currency: "ETB") +
        Core::Money.new(amount_minor: 100, currency: "USD")
    end

    assert_equal "ETB cannot be combined with USD", error.message
  end
end
```

```ruby
require "test_helper"

class Core::IdempotencyKeyTest < ActiveSupport::TestCase
  test "normalizes a caller key without exposing it in derived storage keys" do
    key = Core::IdempotencyKey.new(" checkout-123 ")

    assert_equal "checkout-123", key.to_s
    assert_match(/\A[0-9a-f]{64}\z/, key.digest)
  end

  test "rejects blank and oversized keys" do
    assert_raises(ArgumentError) { Core::IdempotencyKey.new(" ") }
    assert_raises(ArgumentError) { Core::IdempotencyKey.new("x" * 256) }
  end
end
```

- [ ] **Step 2: Run and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/lib/core/money_test.rb test/lib/core/idempotency_key_test.rb
```

Expected: both constants are missing.

- [ ] **Step 3: Implement the value objects**

```ruby
# frozen_string_literal: true

module Core
  Money = Data.define(:amount_minor, :currency) do
    class CurrencyMismatch < Core::Error; end

    def initialize(amount_minor:, currency:)
      normalized_currency = currency.to_s.upcase
      fail ArgumentError, "amount_minor must be an Integer" unless amount_minor.is_a?(Integer)
      fail ArgumentError, "currency must be ISO-4217 alpha-3" unless normalized_currency.match?(/\A[A-Z]{3}\z/)

      super(amount_minor:, currency: normalized_currency)
    end

    def +(other)
      assert_same_currency!(other)
      self.class.new(amount_minor: amount_minor + other.amount_minor, currency:)
    end

    def -(other)
      assert_same_currency!(other)
      self.class.new(amount_minor: amount_minor - other.amount_minor, currency:)
    end

    private

    def assert_same_currency!(other)
      return if other.is_a?(self.class) && other.currency == currency

      other_currency = other.respond_to?(:currency) ? other.currency : other.class.name
      fail CurrencyMismatch, "#{currency} cannot be combined with #{other_currency}"
    end
  end
end
```

```ruby
# frozen_string_literal: true

require "digest"

module Core
  IdempotencyKey = Data.define(:value) do
    MAX_LENGTH = 255

    def initialize(value)
      normalized = value.to_s.strip
      fail ArgumentError, "idempotency key is required" if normalized.empty?
      fail ArgumentError, "idempotency key exceeds 255 bytes" if normalized.bytesize > MAX_LENGTH

      super(value: normalized)
    end

    def to_s = value
    def digest = Digest::SHA256.hexdigest(value)
  end
end
```

- [ ] **Step 4: Verify GREEN**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/lib/core/money_test.rb test/lib/core/idempotency_key_test.rb
```

Expected: 4 tests, 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/lib/core/money.rb app/lib/core/idempotency_key.rb test/lib/core/money_test.rb test/lib/core/idempotency_key_test.rb
git commit -m "feat(core): add money and idempotency values"
```

## Task 4: Add transaction-scoped advisory locks

**Files:**
- Create: `app/lib/core/database/advisory_lock.rb`
- Create: `test/lib/core/database/advisory_lock_test.rb`

- [ ] **Step 1: Write the failing lock test**

```ruby
require "test_helper"

class Core::Database::AdvisoryLockTest < ActiveSupport::TestCase
  test "requires an open transaction" do
    assert_raises(ArgumentError) do
      Core::Database::AdvisoryLock.acquire!("purchase-limit", "user-1", "ticket-type-1")
    end
  end

  test "acquires a stable transaction lock" do
    result = ApplicationRecord.transaction do
      Core::Database::AdvisoryLock.acquire!("purchase-limit", "user-1", "ticket-type-1")
      :locked
    end

    assert_equal :locked, result
  end
end
```

- [ ] **Step 2: Run and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/lib/core/database/advisory_lock_test.rb
```

Expected: missing constant failure.

- [ ] **Step 3: Implement the PostgreSQL helper**

```ruby
# frozen_string_literal: true

module Core
  module Database
    module AdvisoryLock
      module_function

      def acquire!(*parts)
        connection = ApplicationRecord.connection
        fail ArgumentError, "advisory lock requires an open transaction" unless connection.transaction_open?

        key = parts.map(&:to_s).join(":")
        sql = ApplicationRecord.sanitize_sql_array(
          ["SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", key]
        )
        connection.select_value(sql)
      end
    end
  end
end
```

- [ ] **Step 4: Run unit and two-connection serialization tests**

Add this non-transactional test case so each worker owns a separate connection and the assertion does not depend on a timing sleep:

```ruby
class Core::Database::AdvisoryLockSerializationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "serializes two transactions using the same key" do
    first_has_lock = Queue.new
    allow_first_commit = Queue.new
    order = Queue.new

    first = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          Core::Database::AdvisoryLock.acquire!("order", "same-id")
          order << :first_entered
          first_has_lock << true
          allow_first_commit.pop
        end
        order << :first_committed
      end
    end

    first_has_lock.pop
    second = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          Core::Database::AdvisoryLock.acquire!("order", "same-id")
          order << :second_entered
        end
      end
    end

    allow_first_commit << true
    [first, second].each(&:join)

    assert_equal %i[first_entered first_committed second_entered], 3.times.map { order.pop }
  end
end
```

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/lib/core/database/advisory_lock_test.rb
```

Expected: both API and serialization tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/lib/core/database/advisory_lock.rb test/lib/core/database/advisory_lock_test.rb
git commit -m "feat(core): add transaction advisory locks"
```

## Task 5: Add the transactional outbox

**Files:**
- Create: `db/migrate/20260717000100_create_core_outbox_events.rb`
- Create: `app/models/core/outbox_event.rb`
- Create: `app/services/core/outbox/publish.rb`
- Create: `app/services/core/outbox/dispatch.rb`
- Create: `app/jobs/core/dispatch_outbox_event_job.rb`
- Create: `test/fixtures/core_outbox_events.yml`
- Modify: `test/test_helper.rb`
- Create: `test/services/core/outbox/publish_test.rb`
- Create: `test/jobs/core/dispatch_outbox_event_job_test.rb`

- [ ] **Step 1: Write failing publication and dispatch tests**

```ruby
require "test_helper"

class Core::Outbox::PublishTest < ActiveSupport::TestCase
  test "publishes once for one aggregate idempotency key" do
    aggregate = organizations_organizations(:one)

    assert_difference("Core::OutboxEvent.count", 1) do
      2.times do
        Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.published",
          aggregate:,
          payload: { event_id: "event-id" },
          idempotency_key: "publish:event-id:1"
        )
      end
    end
  end

  test "rejects sensitive payload keys" do
    aggregate = organizations_organizations(:one)

    assert_raises(Core::Outbox::Publish::SensitivePayload) do
      Core::Outbox::Publish.call(
        topic: "ticketing",
        event_type: "ticketing.credential.issued",
        aggregate:,
        payload: { qr_token: "secret" },
        idempotency_key: "credential:1"
      )
    end
  end

  test "rejects reuse of one key for different content" do
    aggregate = organizations_organizations(:one)
    Core::Outbox::Publish.call(
      topic: "events", event_type: "events.published", aggregate:,
      payload: { event_id: "first" }, idempotency_key: "publish:collision"
    )

    assert_raises(Core::Outbox::Publish::IdempotencyConflict) do
      Core::Outbox::Publish.call(
        topic: "events", event_type: "events.published", aggregate:,
        payload: { event_id: "different" }, idempotency_key: "publish:collision"
      )
    end
  end
end
```

```ruby
require "test_helper"

class Core::DispatchOutboxEventJobTest < ActiveJob::TestCase
  test "marks the event published only after the handler succeeds" do
    event = core_outbox_events(:pending)
    handler = ->(outbox_event) { assert_equal event.id, outbox_event.id }

    Rails.application.config.x.outbox_handlers = { event.event_type => handler }
    perform_enqueued_jobs { Core::DispatchOutboxEventJob.perform_later(event.id) }

    assert_not_nil event.reload.published_at
  ensure
    Rails.application.config.x.outbox_handlers = {}
  end
end
```

- [ ] **Step 2: Run and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/outbox/publish_test.rb test/jobs/core/dispatch_outbox_event_job_test.rb
```

Expected: missing outbox table/classes.

- [ ] **Step 3: Create the outbox schema**

The migration creates `core_outbox_events` with UUIDv7 ID, required `topic`, `event_type`, `aggregate_type`, `aggregate_id`, `payload` JSONB default `{}`, unique `idempotency_key`, `occurred_at`, `available_at`, nullable `published_at`, nonnegative `attempts`, nullable `last_error_code`, `locked_at`, and timestamps. Add indexes on `(published_at, available_at, id)`, `(aggregate_type, aggregate_id, occurred_at)`, and `event_type`. Add checks for nonblank discriminator fields, `available_at >= occurred_at`, and `published_at IS NULL OR published_at >= occurred_at`.

- [ ] **Step 4: Implement publication**

```ruby
# frozen_string_literal: true

module Core
  module Outbox
    class Publish < Core::BaseService
      class SensitivePayload < Core::Error; end
      class IdempotencyConflict < Core::Error; end

      FORBIDDEN_KEYS = %w[answer consent_content qr_token pnr password account_number].freeze

      def initialize(topic:, event_type:, aggregate:, payload:, idempotency_key:)
        @topic = topic
        @event_type = event_type
        @aggregate = aggregate
        @payload = payload.deep_stringify_keys
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        validate_payload!
        event = Core::OutboxEvent.create_or_find_by!(idempotency_key: @idempotency_key.to_s) do |row|
          row.assign_attributes(
            topic: @topic,
            event_type: @event_type,
            aggregate: @aggregate,
            payload: @payload,
            occurred_at: Time.current,
            available_at: Time.current
          )
        end
        verify_same_publication!(event)
        success(event)
      end

      private

      def validate_payload!
        forbidden = nested_keys(@payload) & FORBIDDEN_KEYS
        fail SensitivePayload, "outbox payload contains #{forbidden.join(', ')}" if forbidden.any?
      end

      def nested_keys(value)
        case value
        when Hash
          value.flat_map { |key, nested| [key.to_s, *nested_keys(nested)] }
        when Array
          value.flat_map { |nested| nested_keys(nested) }
        else
          []
        end
      end

      def verify_same_publication!(event)
        same = event.topic == @topic &&
          event.event_type == @event_type &&
          event.aggregate_type == @aggregate.class.base_class.name &&
          event.aggregate_id == @aggregate.id &&
          event.payload == @payload
        return if same

        fail IdempotencyConflict, "outbox idempotency key was reused for different content"
      end
    end
  end
end
```

- [ ] **Step 5: Implement at-least-once dispatch**

Implement dispatch with a short claim transaction and no database lock held during external work:

```ruby
# frozen_string_literal: true

module Core
  module Outbox
    class Dispatch < Core::BaseService
      class MissingHandler < Core::Error; end

      def initialize(event_id:)
        @event_id = event_id
      end

      def call
        event = claim!
        return success(nil) unless event
        return success(event) if event.published_at?

        @claimed = true
        handler_for(event).call(event)
        mark_published!(event)
        success(event.reload)
      rescue StandardError => error
        record_failure!(error) if @claimed
        raise
      end

      private

      def claim!
        Core::OutboxEvent.transaction do
          event = Core::OutboxEvent.lock.find(@event_id)
          return event if event.published_at?
          return if event.locked_at && event.locked_at > 5.minutes.ago

          event.update!(locked_at: Time.current)
          event
        end
      end

      def handler_for(event)
        Rails.application.config.x.outbox_handlers.fetch(event.event_type) do
          raise MissingHandler, "no outbox handler for #{event.event_type}"
        end
      end

      def mark_published!(event)
        Core::OutboxEvent.where(id: event.id, published_at: nil)
          .update_all(published_at: Time.current, locked_at: nil, updated_at: Time.current)
      end

      def record_failure!(error)
        Core::OutboxEvent.where(id: @event_id).update_all(
          attempts: Arel.sql("attempts + 1"),
          last_error_code: error.class.name.to_s.first(120),
          locked_at: nil,
          updated_at: Time.current
        )
      end
    end
  end
end
```

The handler must use the outbox event's `idempotency_key` at its own external/database boundary. Add this job:

```ruby
# frozen_string_literal: true

module Core
  class DispatchOutboxEventJob < ApplicationJob
    queue_as :outbox
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(event_id)
      Core::Outbox::Dispatch.call(event_id:)
    end
  end
end
```

Add a recurring recovery job that claims due unpublished rows with `FOR UPDATE SKIP LOCKED` in batches of 100, advances `available_at` before enqueueing, and passes only IDs to `Core::DispatchOutboxEventJob`.

- [ ] **Step 6: Run migration and tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/outbox/publish_test.rb test/jobs/core/dispatch_outbox_event_job_test.rb
```

Expected: outbox tests pass and duplicate publication creates one row.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260717000100_create_core_outbox_events.rb app/models/core/outbox_event.rb app/services/core/outbox app/jobs/core test/fixtures/core_outbox_events.yml test/test_helper.rb test/services/core/outbox test/jobs/core/dispatch_outbox_event_job_test.rb
git commit -m "feat(core): add transactional outbox"
```

## Task 6: Unify automatic CRUD and transactional command auditing

**Files:**
- Create: `db/migrate/20260717000101_add_audit_key_to_core_audit_logs.rb`
- Create: `app/services/core/audit/record.rb`
- Create: `app/services/core/audit/build_controller_payload.rb`
- Modify: `app/models/core/audit_log.rb`
- Modify: `app/models/concerns/core/auditable_model.rb`
- Modify: `app/controllers/concerns/core/auditable_controller.rb`
- Modify: `app/jobs/core/audit_logger_job.rb`
- Modify: `test/models/core/audit_log_test.rb`
- Modify: `test/models/core/role_test.rb`
- Modify: `test/jobs/core/audit_logger_job_test.rb`
- Create: `test/services/core/audit/record_test.rb`
- Create: `test/services/core/audit/build_controller_payload_test.rb`
- Reuse: `test/integration/admin/users_test.rb`
- Reuse: `test/integration/organizations/owner_organizations_test.rb`
- Reuse: `test/integration/organizations/owner_memberships_test.rb`

- [ ] **Step 1: RED — specify one deletion-safe, retry-safe recorder contract**

```ruby
require "test_helper"

class Core::Audit::RecordTest < ActiveSupport::TestCase
  test "records a payload-safe audit in the caller transaction" do
    organization = organizations_organizations(:one)
    actor = core_users(:super_admin)

    assert_difference("Core::AuditLog.count", 1) do
      Core::Audit::Record.call(
        audit_key: "event.publish:command-1",
        action: "event.publish",
        auditable_type: organization.class.polymorphic_name,
        auditable_id: organization.id,
        actor_type: actor.class.polymorphic_name,
        actor_id: actor.id,
        audited_changes: { status: { old: "draft", new: "published" } },
        metadata: { command_id: "command-1" },
        request_uuid: "request-1",
        ip_address: "127.0.0.1",
        user_agent: "test"
      )
    end
  end

  test "rolls audit back with the business transaction" do
    organization = organizations_organizations(:one)

    assert_no_difference("Core::AuditLog.count") do
      ApplicationRecord.transaction do
        Core::Audit::Record.call(
          audit_key: "event.publish:rollback",
          action: "event.publish",
          auditable_type: organization.class.polymorphic_name,
          auditable_id: organization.id
        )
        raise ActiveRecord::Rollback
      end
    end
  end

  test "returns the same audit for an identical replay" do
    attributes = {
      audit_key: "ticket.issue:ticket-1",
      action: "ticket.issue",
      auditable_type: "Ticketing::Ticket",
      auditable_id: SecureRandom.uuid,
      audited_changes: { status: { old: "pending", new: "active" } }
    }

    assert_difference("Core::AuditLog.count", 1) do
      first = Core::Audit::Record.call(**attributes)
      second = Core::Audit::Record.call(**attributes.deep_dup)

      assert first.success?
      assert second.success?
      assert_equal first.value.id, second.value.id
    end
  end

  test "rejects reuse of an audit key for a different payload" do
    base = {
      audit_key: "payment.accept:payment-1",
      action: "payment.accept",
      auditable_type: "Orders::Payment",
      auditable_id: SecureRandom.uuid
    }

    Core::Audit::Record.call(**base, metadata: { provider_status: "settled" })

    assert_raises(Core::Audit::Record::ReplayConflict) do
      Core::Audit::Record.call(**base, metadata: { provider_status: "failed" })
    end
  end

  test "rejects credential and attendee secrets recursively" do
    organization = organizations_organizations(:one)

    assert_raises(Core::Audit::Record::SensitivePayload) do
      Core::Audit::Record.call(
        audit_key: "ticket.issue:secret-test",
        action: "ticket.issue",
        auditable_type: organization.class.polymorphic_name,
        auditable_id: organization.id,
        metadata: { delivery: { qr_token: "must-not-be-audited" } }
      )
    end
  end
end
```

- [ ] **Step 2: Run and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/core/audit/record_test.rb
```

Expected: missing `audit_key` schema and `Core::Audit::Record`.

- [ ] **Step 3: GREEN — add the idempotency boundary and implement the only audit writer**

```ruby
class AddAuditKeyToCoreAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :core_audit_logs, :audit_key, :string, null: false
    add_index :core_audit_logs, :audit_key, unique: true
  end
end
```

This is a clean pre-launch migration. If local development rows already exist, reset the development database rather than adding a nullable compatibility phase. `Core::AuditLog` validates `audit_key`, but uniqueness authority remains the PostgreSQL index.

```ruby
# frozen_string_literal: true

module Core
  module Audit
    class Record < Core::BaseService
      class SensitivePayload < Core::Error; end
      class ReplayConflict < Core::Error; end

      REPLAY_FIELDS = %w[
        action auditable_type auditable_id actor_type actor_id audited_changes metadata
        request_uuid ip_address user_agent
      ].freeze

      FORBIDDEN_KEY_PATTERNS = [
        /password/i,
        /(^|_)token($|_)/i,
        /secret/i,
        /ciphertext/i,
        /(^|_)qr($|_)/i,
        /(^|_)pnr($|_)/i,
        /lookup_code/i,
        /account_number/i,
        /provider_payload/i,
        /webhook_body/i,
        /answer/i,
        /consent_content/i
      ].freeze

      def initialize(audit_key:, action:, auditable_type:, auditable_id:, actor_type: nil,
        actor_id: nil, audited_changes: {}, metadata: {}, request_uuid: nil,
        ip_address: nil, user_agent: nil)
        @attributes = {
          audit_key:,
          action: action.to_s,
          auditable_type:,
          auditable_id:,
          actor_type:,
          actor_id:,
          audited_changes: audited_changes.presence || {},
          metadata: metadata.presence || {},
          request_uuid:,
          ip_address:,
          user_agent:
        }
      end

      def call
        validate_identity!
        validate_payload!
        audit = create_or_find_audit
        validate_replay!(audit)
        success audit
      end

      private

      def validate_identity!
        fail ArgumentError, "audit_key is required" if @attributes[:audit_key].blank?
        fail ArgumentError, "action is required" if @attributes[:action].blank?
        fail ArgumentError, "auditable_type is required" if @attributes[:auditable_type].blank?
        fail ArgumentError, "auditable_id is required" if @attributes[:auditable_id].blank?
        if @attributes[:actor_type].present? != @attributes[:actor_id].present?
          fail ArgumentError, "actor_type and actor_id must be present together"
        end
      end

      def validate_payload!
        keys = nested_keys(@attributes.slice(:audited_changes, :metadata))
        forbidden = keys.select do |key|
          FORBIDDEN_KEY_PATTERNS.any? { |pattern| pattern.match?(key) }
        end.uniq
        return if forbidden.empty?

        fail SensitivePayload, "audit payload contains forbidden keys: #{forbidden.join(', ')}"
      end

      def create_or_find_audit
        Core::AuditLog.create!(@attributes)
      rescue ActiveRecord::RecordNotUnique
        Core::AuditLog.find_by!(audit_key: @attributes.fetch(:audit_key))
      end

      def validate_replay!(audit)
        expected = canonical(@attributes.stringify_keys.slice(*REPLAY_FIELDS))
        actual = canonical(audit.attributes.slice(*REPLAY_FIELDS))
        return if expected == actual

        fail ReplayConflict, "audit_key was already used for a different payload"
      end

      def canonical(value)
        ActiveSupport::JSON.decode(ActiveSupport::JSON.encode(value))
      end

      def nested_keys(value)
        case value
        when Hash
          value.flat_map { |key, nested| [key.to_s, *nested_keys(nested)] }
        when Array
          value.flat_map { |nested| nested_keys(nested) }
        else
          []
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the recorder tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/core/audit_log_test.rb test/services/core/audit/record_test.rb
```

Expected: PASS, including rollback, identical replay, replay conflict, and recursive sensitive-key rejection.

- [ ] **Step 5: RED — preserve the controller DSL's automatic diff behavior**

Move the existing advanced-signature behavior tests out of `test/jobs/core/audit_logger_job_test.rb` into `test/services/core/audit/build_controller_payload_test.rb`. Keep exact coverage for:

- create, update, and destroy snapshots;
- no audit when nothing changed;
- main-record `only` and `except` filtering;
- associated-record additions, removals, and field filtering;
- configured action labels;
- deleted records represented by their captured type and ID;
- actor, request UUID, IP address, and user agent preservation.

The builder result must already match the `Core::Audit::Record` keyword contract and contain a stable controller key such as `controller:<request_uuid>:<record_type>:<record_id>:<action_label>`. It returns `success(nil)` when the calculated diff is empty.

```ruby
test "automatically produces the filtered update diff" do
  role = core_roles(:core_admin)
  actor = core_users(:super_admin)

  result = Core::Audit::BuildControllerPayload.call(
    record_id: role.id,
    record_type: role.class.polymorphic_name,
    before_main: snapshot(role, name: "Old", description: "Hidden old"),
    after_main: snapshot(role, name: "New", description: "Hidden new"),
    before_associated: {},
    after_associated: {},
    action_name: "update",
    controller_name: "admin/roles",
    configs: [ { only: [ :name ], except: [], associated: {}, action: nil } ],
    actor_id: actor.id,
    actor_type: actor.class.polymorphic_name,
    request_uuid: "request-automatic-diff",
    ip_address: "127.0.0.1",
    user_agent: "test"
  )

  assert result.success?
  changes = result.value.fetch(:audited_changes).with_indifferent_access.dig(:main, :changes)
  assert_equal({ "old" => "Old", "new" => "New" }, changes.fetch(:name).stringify_keys)
  assert_not changes.key?(:description)
end

private

def snapshot(record, **overrides)
  {
    id: record.id,
    type: record.class.polymorphic_name,
    attributes: record.attributes.merge(overrides.stringify_keys),
    timestamp: Time.current.to_f
  }
end
```

- [ ] **Step 6: GREEN — extract normalization from the job without changing the DSL**

Create `Core::Audit::BuildControllerPayload < Core::BaseService`. Move the existing proven `calculate_changes`, `diff_records`, `filter_changes`, association normalization, and action-label resolution from `Core::AuditLoggerJob` into this pure builder. It receives the before/after snapshots and active DSL configurations and returns only normalized scalar/JSON attributes accepted by `Core::Audit::Record`:

```ruby
result = Core::Audit::BuildControllerPayload.call(
  record_id:,
  record_type:,
  before_main:,
  after_main:,
  before_associated:,
  after_associated:,
  action_name:,
  controller_name:,
  configs:,
  actor_id:,
  actor_type:,
  request_uuid:,
  ip_address:,
  user_agent:
)

payload = result.value
Core::AuditLoggerJob.perform_later(**payload) if payload
```

Keep all three public DSL entry points and their behavior:

```ruby
auditable on: %i[create update destroy], only: %i[name status]
auditable_model Events::Event
auditable_record_for :destroy, -> { @event }
```

`Core::AuditableController` still captures before state in `before_action`, captures after state in `after_action`, automatically calculates main and associated diffs through the builder, and enqueues controller CRUD audits. The controller author does not manually calculate changes.

The existing `transactional:` name is misleading because an `after_action` job is not atomic with a CRUD transaction that already committed. Replace it with `required: true` in the DSL and update all local call sites in this same pre-launch commit. `required: true` means payload construction or enqueue failure raises and fails the request; it does not promise rollback of already committed controller CRUD. Commands requiring atomic evidence use the synchronous path below.

- [ ] **Step 7: GREEN — reduce the job to one normalized recorder call**

```ruby
# frozen_string_literal: true

module Core
  class AuditLoggerJob < ApplicationJob
    queue_as :audit
    retry_on StandardError, wait: 5.seconds, attempts: 3

    def perform(**payload)
      Core::Audit::Record.call(**payload).value
    end
  end
end
```

Delete `perform_legacy`, snapshot diffing, constantization, record reloading, and the dual signature from the job. Do not use `discard_on ActiveRecord::RecordNotFound`: the normalized payload contains the captured polymorphic type and ID, so create/update/destroy audits remain writable even if the auditable or actor is later deleted. Job retry is safe because `audit_key` is unique and identical replays return the existing row.

- [ ] **Step 8: GREEN — preserve model convenience methods through the same two paths**

`Core::AuditableModel#record_audit!` builds the same scalar payload and calls `Core::Audit::Record` synchronously, returning `result.value`. `record_audit_later!` builds the same payload and enqueues `Core::AuditLoggerJob`. Both accept optional `audit_key:`; when omitted, generate `model:<model_name>:<id>:<action>:<SecureRandom.uuid>` because these convenience calls have no external idempotency identity.

Neither method may call `audit_logs.create!` directly. Existing verification controllers may keep calling `record_audit!`; they now converge automatically through the model helper. Remove `dependent: :destroy` from the model's `has_many :audit_logs` association. Audit rows intentionally retain captured polymorphic type/ID after the source record is deleted; deleting an auditable must never erase its history.

```ruby
test "retains audit history after the auditable is deleted" do
  role = Core::Role.create!(name: "Temporary Audit Role", code: "TEMP_AUDIT_ROLE")
  audit = role.record_audit!("role.created", audit_key: "role.created:#{role.id}")

  role.destroy!

  assert Core::AuditLog.exists?(audit.id)
  assert_nil audit.reload.auditable
  assert_equal "Core::Role", audit.auditable_type
  assert_equal role.id, audit.auditable_id
end
```

- [ ] **Step 9: Run controller, builder, job, and model regression tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/core/audit/build_controller_payload_test.rb \
  test/jobs/core/audit_logger_job_test.rb \
  test/models/core/role_test.rb \
  test/integration/admin/users_test.rb \
  test/integration/organizations/owner_organizations_test.rb \
  test/integration/organizations/owner_memberships_test.rb
```

Expected: PASS. Controller authors retain automatic create/update/destroy and associated diffs, destroy audits survive missing records, model helpers preserve return/enqueue behavior, and job retries create one log.

- [ ] **Step 10: Use synchronous audit recording in authoritative commands**

New payment, ticket issuance, credential replacement, refund, finance-ledger, resale-completion, and payout commands call the recorder after their state mutation but before their transaction commits:

```ruby
Core::Audit::Record.call(
  audit_key: "payment.accept:#{payment.id}:#{provider_event.id}",
  action: "payment.accept",
  auditable_type: payment.class.polymorphic_name,
  auditable_id: payment.id,
  actor_type: actor&.class&.polymorphic_name,
  actor_id: actor&.id,
  audited_changes: {
    status: { old: previous_status, new: payment.status }
  },
  metadata: {
    order_id: payment.order_id,
    provider_event_id: provider_event.id
  }
).value
```

The surrounding transaction rolls back if recorder validation or insertion raises. Commands use a deterministic key from their existing aggregate/provider/idempotency identity; they never generate a fresh random audit key during retry. Do not pass QR/PNR data, credential claims, registration answers, consent content, account numbers, provider payloads, webhook bodies, secrets, or tokens.

Controller CRUD audits remain automatic and asynchronous. Command audits are explicit and synchronous because they record meaningful business transitions rather than every changed database column.

- [ ] **Step 11: Verify the single-writer invariant**

```bash
rg -n "AuditLog\.(create|create!)|audit_logs\.(create|create!)|perform_legacy" app --glob '*.rb'
```

Expected: the only `Core::AuditLog` creation is in `Core::Audit::Record`; no model, controller, job, or command writes the table directly, and `perform_legacy` is absent.

Both entry points now converge without removing the controller DSL:

```text
Controller DSL -> automatic snapshot diff -> normalized payload -> AuditLoggerJob --+
                                                                                |
Financial/ticket command -> explicit business diff inside transaction ----------+-> Core::Audit::Record -> Core::AuditLog
```

- [ ] **Step 12: Run all audit and resource tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/core/audit \
  test/jobs/core/audit_logger_job_test.rb \
  test/models/core/audit_log_test.rb \
  test/models/core/role_test.rb \
  test/integration/admin \
  test/integration/organizations
```

Expected: audits remain visible on CRUD surfaces, automatic diffs match previous behavior, async retries are idempotent, destroy evidence survives deletion, and synchronous audit rollback is proven.

- [ ] **Step 13: Commit**

```bash
git add db/migrate/20260717000101_add_audit_key_to_core_audit_logs.rb db/schema.rb app/services/core/audit app/models/core/audit_log.rb app/models/concerns/core/auditable_model.rb app/controllers/concerns/core/auditable_controller.rb app/jobs/core/audit_logger_job.rb test/models/core/audit_log_test.rb test/models/core/role_test.rb test/services/core/audit test/jobs/core/audit_logger_job_test.rb test/integration/admin test/integration/organizations
git commit -m "refactor(core): unify audit recording"
```

## Task 7: Configure application-level encryption and safe filtering

**Files:**
- Modify: `config/application.rb`
- Modify: `config/environments/test.rb`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Create: `test/config/active_record_encryption_test.rb`

- [ ] **Step 1: Generate environment encryption keys securely**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:encryption:init
```

Expected: Rails prints three keys. Store them in environment-specific credentials or environment variables; never commit the output.

- [ ] **Step 2: Write the failing configuration test**

```ruby
require "test_helper"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  test "encrypted fixtures are enabled in test" do
    assert Rails.application.config.active_record.encryption.encrypt_fixtures
  end

  test "sensitive event-platform parameter names are filtered" do
    filters = Rails.application.config.filter_parameters.map(&:to_s)

    %w[answer consent qr_token lookup_code account_token holder_name].each do |name|
      assert filters.any? { |filter| filter.include?(name) }, "expected #{name} to be filtered"
    end
  end
end
```

- [ ] **Step 3: Run and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/config/active_record_encryption_test.rb
```

Expected: encrypted fixtures and new filters are absent.

- [ ] **Step 4: Configure encryption and filtering**

Set `config.active_record.encryption.primary_key`, `deterministic_key`, and `key_derivation_salt` from credentials/environment in `config/application.rb`. Enable `config.active_record.encryption.encrypt_fixtures = true` in test. Do not enable `support_unencrypted_data` or `extend_queries`; this pre-launch schema has no plaintext compatibility period.

Append these filter fragments: `answer`, `consent`, `qr_token`, `lookup_code`, `phone_hash`, `account_token`, `holder_name`, `payout`, `provider_payload`, and `signature`.

- [ ] **Step 5: Verify GREEN**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/config/active_record_encryption_test.rb
```

Expected: configuration tests pass without printing keys.

- [ ] **Step 6: Commit**

```bash
git add config/application.rb config/environments/test.rb config/initializers/filter_parameter_logging.rb test/config/active_record_encryption_test.rb
git commit -m "chore(core): configure encrypted domain data"
```

## Task 8: Create domain namespace bases (no `/api/v1` versioning yet)

> **Decision (2026-07-19):** Skip URL versioning for now — the project is pre-launch with
> no external API consumers. Routes stay unversioned at the root. Namespace base classes
> are still created because they are useful regardless of versioning. Revisit `/api/v1`
> only when a real external consumer or breaking-change policy requires it. The
> `config/routes.rb` and integration tests/Postman collections are NOT modified by this
> task.

**Files:**
- Create: `app/models/catalog/application_record.rb`
- Create: `app/models/ticketing/application_record.rb`
- Create: `app/models/orders/application_record.rb`
- Create: `app/models/finance/application_record.rb`
- Create: `app/models/marketplace/application_record.rb`
- Create: `app/models/links/application_record.rb`
- Create: matching `app/controllers/<namespace>/application_controller.rb`

- [ ] **Step 1: Add namespace base records/controllers**

Each application record follows this complete pattern:

```ruby
# frozen_string_literal: true

module Catalog
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
```

Each authenticated namespace controller follows:

```ruby
# frozen_string_literal: true

module Catalog
  class ApplicationController < Core::ApplicationController
  end
end
```

Use the equivalent namespace in each file. No route changes, no test/Postman changes.

- [ ] **Step 2: Run the full suite to confirm no regressions**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: all existing tests still pass (these are additive base classes only).

- [ ] **Step 3: Commit**

```bash
git add app/models app/controllers
git commit -m "refactor(core): establish domain namespace base classes"
```

## Task 9: Teach the domain generator about business `type`

**Files:**
- Modify: `lib/generators/domain_module/domain_module_generator.rb`
- Modify: `lib/generators/domain_module/templates/model.rb.tt`
- Create or modify: generator tests under `test/lib/generators/domain_module/`
- Modify: `docs/DOMAIN_MODULE_GENERATOR.md`

- [ ] **Step 1: Write a failing generator test**

Generate a sample resource with `--business-type` and assert that the generated model contains `self.inheritance_column = nil`; generate without the option and assert it does not.

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/lib/generators/domain_module/domain_module_generator_test.rb
```

Expected: failure because the option is unknown.

- [ ] **Step 2: Add the explicit generator option**

Add:

```ruby
class_option :business_type,
  type: :boolean,
  default: false,
  desc: "Disable STI because the resource uses type as a business discriminator"
```

Add this template fragment inside the generated class:

```erb
<% if options[:business_type] -%>
    self.inheritance_column = nil
<% end -%>
```

Do not infer the option merely because a column happens to be named `type`; the generated intent must remain reviewable.

- [ ] **Step 3: Run generator tests and verify generated Ruby syntax**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/lib/generators/domain_module/domain_module_generator_test.rb
PATH="$HOME/.asdf/shims:$PATH" bundle exec ruby -c tmp/domain_module_generator/business_type_model.rb
```

Expected: generator tests pass and generated Ruby reports `Syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add lib/generators/domain_module test/lib/generators/domain_module docs/DOMAIN_MODULE_GENERATOR.md
git commit -m "feat(generator): support business type columns"
```

## Task 10: Core foundation acceptance gate

**Files:**
- Verify: all files changed by Tasks 1–9

- [ ] **Step 1: Run focused Core tests**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/errors/core test/services/core test/lib/core test/controllers/concerns/core test/jobs/core
```

Expected: zero failures and zero errors.

- [ ] **Step 2: Run the complete repository gate**

```bash
PATH="$HOME/.asdf/shims:$PATH" bin/ci
```

Expected: setup, style, dependency audit, Brakeman, Rails tests, and seed replant pass.

- [ ] **Step 3: Verify architecture rules**

```bash
rg -n "support_unencrypted_data|extend_queries|perform_legacy|legacy" app config
```

Expected: no compatibility-mode encryption and no dual audit signature.

- [ ] **Step 4: Commit any acceptance-only corrections**

```bash
git add app config db lib test docs
git commit -m "test(core): verify event platform foundation"
```
