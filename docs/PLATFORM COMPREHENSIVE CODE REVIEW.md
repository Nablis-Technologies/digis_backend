# Core Framework — Comprehensive Code Review

**Date**: May 18, 2026
**Scope**: All implemented files in `app/`, `lib/`, `db/`, `test/`, `config/`
**Review Lens**: Maintainability, Extensibility, Composability, Scalability, Best Practices

---

## Executive Summary

The Core framework is **structurally sound** with well-thought-out architecture. The concern-based controller system, RBAC, audit trail, and review workflow are production-grade. However, there are **18 issues** across 4 severity levels that must be addressed before the system can be considered maintainable and scalable.

| Severity | Count | Summary |
|----------|-------|---------|
| **Critical** | 3 | Data integrity, security, and correctness issues |
| **High** | 5 | Architecture and design problems that will cause pain at scale |
| **Medium** | 6 | Maintainability and consistency issues |
| **Low** | 4 | Style, naming, and minor improvements |

---

## CRITICAL ISSUES

### C1: `password_digest` NOT NULL constraint blocks shadow user creation

**File**: `db/schema.rb:123`
**File**: `db/migrate/20260516000200_create_core_users.rb:8`

The `password_digest` column is `null: false`. The architecture requires shadow users (phone-only, no password) for frictionless ticket purchases. This constraint makes it **impossible** to create a shadow user.

```ruby
# Current migration:
t.string :password_digest, null: false  # ← BLOCKS shadow users

# Required:
change_column_null :core_users, :password_digest, true
```

**Impact**: The core "no account required to buy tickets" feature cannot work.

**Fix**: Add a migration to make `password_digest` nullable (as designed in the auth architecture doc). The `UserAuthenticatable` concern already handles this correctly with `has_secure_password validations: false` — the database constraint is the blocker.

---

### C2: `temp_password` column still exists in schema but was removed from architecture

**File**: `db/schema.rb:125`
**File**: `db/migrate/20260516000200_create_core_users.rb:7`

The `temp_password` boolean column exists in the database. The previous code review identified this as a security concern (leaking temp password state in serializers). The column was supposed to be removed but the migration to drop it was never created.

**Impact**: Dead column that could be misused. Wastes storage. Confuses future developers.

**Fix**: Add to the phone-first auth migration:
```ruby
remove_column :core_users, :temp_password, :boolean
```

---

### C3: `AuthService#refresh_access_token` destroys old token before creating new — no rollback on failure

**File**: `app/services/platform/auth_service.rb:56-64`

```ruby
# Lines 56-64:
old_device_id = refresh_token.device_id
user = refresh_token.user
refresh_token.destroy          # ← DESTROYED FIRST

access_token = Core::TokenService.issue(...)
new_refresh = create_refresh_token(user, request)  # ← CREATION CAN FAIL
new_refresh.update!(device_id: old_device_id)
```

If `create_refresh_token` raises an exception (e.g., DB constraint violation), the old refresh token is already destroyed and the user is **locked out** with no valid refresh token.

**Fix**: Wrap in a transaction and create the new token before destroying the old:
```ruby
def refresh_access_token(refresh_token_value, request)
  refresh_token = Core::RefreshToken.active.find_by(refresh_token: refresh_token_value)
  raise Core::AuthenticationError.new("Invalid token", code: "invalid_token") unless refresh_token

  validate_device!(refresh_token, request)

  ActiveRecord::Base.transaction do
    old_device_id = refresh_token.device_id
    user = refresh_token.user

    # Create new token FIRST
    new_refresh = create_refresh_token(user, request)
    new_refresh.update!(device_id: old_device_id)

    # Then destroy old
    refresh_token.destroy

    access_token = Core::TokenService.issue(
      Core::TokenService.access_token_payload(user)
    )

    {
      access_token: access_token,
      refresh_token: new_refresh.refresh_token,
      user: user
    }
  end
end
```

---

## HIGH ISSUES

### H1: `AuditableController` concern is 507 lines — violates Single Responsibility

**File**: `app/controllers/concerns/platform/auditable_controller.rb`

This concern does **too much**:
- DSL definition (`auditable`, `auditable_model`, `auditable_record_for`)
- Config validation (97 lines of `validate_audit_config!`)
- Snapshot capture (`capture_audit_snapshot`)
- Record resolution with 5 priority levels (`perform_record_resolution`, 87 lines)
- State serialization (`capture_record_state`)
- Job enqueuing with transactional logic (`enqueue_audit`)
- Error formatting with ASCII art (`log_resolution_failure`, 50+ lines)

**Impact**: Nearly impossible to test comprehensively. Any change risks breaking unrelated functionality. New developers cannot understand the concern without reading 500+ lines.

**Fix**: Extract into focused components:
```
app/services/platform/audit/
  config_validator.rb       # Validates auditable DSL config
  snapshot_capturer.rb      # Captures before/after state
  record_resolver.rb        # Resolves the auditable record (5 priority levels)
  state_serializer.rb       # Serializes record state to hash
  change_calculator.rb      # Diffs before/after snapshots
```

The concern should then be ~50 lines of orchestration:
```ruby
module Core
  module AuditableController
    extend ActiveSupport::Concern

    included do
      class_attribute :_audit_configs, default: []
      before_action :capture_audit_snapshot, if: :audit_needed?
      after_action :enqueue_audit, if: :audit_needed?
    end

    class_methods do
      def auditable(**config)
        Audit::ConfigValidator.validate!(config)
        self._audit_configs += [ Audit::ConfigValidator.normalize(config) ]
      end
    end

    private

    def capture_audit_snapshot
      @audit_snapshot = Audit::SnapshotCapturer.call(self)
    end

    def enqueue_audit
      record = Audit::RecordResolver.call(self, _audit_configs)
      return unless record

      after_state = Audit::StateSerializer.call(record)
      AuditLoggerJob.perform_later(
        record_id: record.id,
        record_type: record.class.name,
        before_main: @audit_snapshot[:before_main],
        after_main: after_state,
        # ...
      )
    end
  end
end
```

---

### H2: `AuditLoggerJob` is 312 lines — job should not contain business logic

**File**: `app/jobs/platform/audit_logger_job.rb`

The job contains:
- Legacy signature support (15 lines)
- Change calculation logic (55 lines)
- Associated record diffing (57 lines)
- Field filtering (35 lines)
- Config normalization (17 lines)
- Action label resolution (14 lines)

**Impact**: Jobs should be thin dispatchers. This job is a full audit engine. Testing requires mocking the entire change-calculation pipeline.

**Fix**: Extract change calculation to `Audit::ChangeCalculator`:
```ruby
module Core
  class AuditLoggerJob < ApplicationJob
    queue_as :audit
    retry_on StandardError, wait: 5.seconds, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    def perform(record_id:, record_type:, before_main:, after_main:,
                before_associated:, after_associated:, action_name:,
                controller_name:, configs:, actor_id:, actor_type:,
                request_uuid:, ip_address:, user_agent:)

      record = record_type.constantize.find_by(id: record_id)
      return unless record

      actor = resolve_actor(actor_type, actor_id)
      changes = Audit::ChangeCalculator.call(
        before_main:, after_main:,
        before_associated:, after_associated:,
        configs:
      )
      return if changes.blank?

      action_label = resolve_action_label(action_name, configs)

      record.record_audit!(
        action_label,
        audited_changes: changes,
        metadata: { controller: controller_name, action: action_name, request_uuid: },
        actor:, request_uuid:, ip_address:, user_agent:
      )
    end

    private

    def resolve_actor(actor_type, actor_id)
      return unless actor_type && actor_id
      actor_type.constantize.find_by(id: actor_id)
    end

    def resolve_action_label(action_name, configs)
      configs.each do |config|
        next unless config[:action]
        if config[:action].is_a?(Hash)
          return config[:action][action_name.to_sym] if config[:action][action_name.to_sym]
        elsif config[:action].is_a?(String)
          return config[:action]
        end
      end
      action_name
    end
  end
end
```

---

### H3: `ReviewableController` concern is 316 lines — mixes state machine, authorization, and rendering

**File**: `app/controllers/concerns/platform/reviewable_controller.rb`

This concern handles:
- DSL for review contexts and transitions
- Dynamic method definition (`define_review_action_method`)
- Review action execution with feedback extraction
- Model updates during review
- Authorization checks
- Error rendering

**Impact**: The state machine logic (transitions, statuses, actions) should be a separate service. The concern should only handle HTTP concerns (params, rendering).

**Fix**: Extract `Review::StateMachine`:
```ruby
# app/services/platform/review/state_machine.rb
module Core
  module Review
    class StateMachine
      def initialize(configs)
        @configs = configs
      end

      def valid_transition?(context, from, to)
        transitions = config_for(context)[:transitions]
        return true if transitions.blank?
        allowed = transitions[from || initial_status(context)] || []
        allowed.include?(to)
      end

      def config_for(context)
        @configs[context] || default_config
      end

      def initial_status(context)
        config_for(context)[:initial_status]
      end

      def action_config(context, action_name)
        config_for(context)[:actions][action_name.to_sym]
      end

      private

      def default_config
        {
          statuses: %w[draft pending approved rejected modify],
          initial_status: "draft",
          transitions: { "draft" => ["pending"], "pending" => %w[approved rejected modify], "modify" => ["pending"] },
          actions: {
            submit: { status: "pending", require_submission_ready: true },
            approve: { status: "approved" },
            reject: { status: "rejected", require_feedback: true },
            request_modification: { status: "modify", require_feedback: true },
            resubmit: { status: "pending", update_model: true, from: "modify" }
          }
        }
      end
    end
  end
end
```

---

### H4: `User#active_permissions` and `User#active_role_codes` use raw SQL strings instead of Arel

**File**: `app/models/platform/user.rb:57-74`

```ruby
def active_permissions
  @active_permissions ||= Core::Permission
    .joins(role_permissions: { role: :user_roles })
    .where(core_user_roles: { user_id: id })
    .where(core_roles: { active: true }, core_permissions: { active: true })
    .where("core_user_roles.expires_at IS NULL OR core_user_roles.expires_at > ?", Time.current)
    .distinct
    .pluck(:code)
end
```

The raw SQL string `"core_user_roles.expires_at IS NULL OR ..."` is fragile. It hardcodes table names that could change. It's also duplicated between `active_permissions` and `active_role_codes`.

**Fix**: Use a scope on `UserRole`:
```ruby
# app/models/platform/user_role.rb
scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

# app/models/platform/user.rb
def active_permissions
  @active_permissions ||= Core::Permission
    .joins(role_permissions: { role: :user_roles })
    .merge(Core::UserRole.active)
    .where(core_user_roles: { user_id: id })
    .where(core_roles: { active: true }, core_permissions: { active: true })
    .distinct
    .pluck(:code)
end
```

---

### H5: `ApplicationPolicy` hardcodes permission code format — not composable for non-CRUD actions

**File**: `app/policies/platform/application_policy.rb:70-77`

```ruby
def permission_code(action)
  "#{resource_name}.#{action}"
end

def resource_name
  target = record.is_a?(Class) ? record : record.class
  target.model_name.collection
end
```

This generates codes like `"core_users.index"`. But the permission system uses codes like `"roles.index"` (without the `core_` prefix). The `model_name.collection` returns `"core_users"` for `Core::User`, but permissions are registered as `"users"`.

**Impact**: Policy checks will fail silently (return `false`) because the generated permission code doesn't match the registered permission code.

**Fix**: Strip the namespace prefix:
```ruby
def resource_name
  target = record.is_a?(Class) ? record : record.class
  target.model_name.collection.sub(/^core_/, "")
end
```

Or better, make it configurable:
```ruby
def self.permission_resource_name(klass)
  klass.model_name.collection.sub(/^core_/, "")
end
```

---

## MEDIUM ISSUES

### M1: `# frozen_string_literal: true` missing from most files

**Files**: 35 of ~50 files are missing the pragma.

Only 3 files have it:
- `app/controllers/concerns/platform/auditable_controller.rb`
- `app/services/platform/base_service.rb` (in plan, not yet implemented)
- `app/services/platform/otp_service.rb` (in plan, not yet implemented)

**Impact**: Every string literal creates a new object. In a high-throughput API, this adds unnecessary GC pressure. It's also inconsistent code style.

**Fix**: Add to the top of every Ruby file. This is a one-time mechanical change.

---

### M2: `Common` concern forces `before_action :set_object` on ALL controllers that include it

**File**: `app/controllers/concerns/platform/common.rb:10-11`

```ruby
included do
  class_attribute :model_class, default: nil
  before_action :set_clazz
  before_action :set_object, only: %i[show update destroy]  # ← Always runs
end
```

The `set_object` callback runs for `show`, `update`, `destroy` regardless of whether the controller actually needs it. If a controller overrides these actions with custom logic, `set_object` still fires (wasting a DB query).

**Fix**: Make it opt-in or lazy:
```ruby
def set_object
  return if defined?(@obj)
  @obj = if eager_loaded_associations.present?
           @clazz.includes(eager_loaded_associations).find(params[:id])
         else
           @clazz.find(params[:id])
         end
end
```

Or remove the `before_action` and let controllers call it explicitly when needed.

---

### M3: `Filterable` silently swallows ALL errors from Ransack

**File**: `app/controllers/concerns/platform/filterable.rb:11-13`

```ruby
rescue StandardError => error
  Rails.logger.warn("Ransack filter skipped: #{error.class} - #{error.message}")
  records
end
```

This catches `StandardError` which includes `NoMethodError`, `TypeError`, and any other unexpected exception. If Ransack has a bug or the params are malformed in an unexpected way, the error is silently swallowed and the user gets unfiltered results without knowing it.

**Fix**: Only catch Ransack-specific errors:
```ruby
def filter_records(records)
  return records unless params[:q].present?
  return records unless records.respond_to?(:ransack)

  @q = records.ransack(params[:q])
  @q.result(distinct: true)
rescue Ransack::Error, Arel::Error => error
  Rails.logger.warn("Ransack filter skipped: #{error.class} - #{error.message}")
  records
end
```

---

### M4: `Pagination` uses offset-based pagination — will degrade at scale

**File**: `app/controllers/concerns/platform/pagination.rb:44-46`

```ruby
def apply_pagination(records)
  records.order(order_by => order_direction).limit(per_page).offset(paginate_offset)
end
```

Offset pagination requires the database to scan and discard all rows before the offset. At page 10,000 with 25 per page, PostgreSQL scans and discards 249,975 rows.

**Impact**: For events with 50K+ tickets (the target scale), pagination will be slow.

**Fix**: Support cursor-based pagination as an alternative:
```ruby
def apply_pagination(records)
  if params[:cursor].present?
    cursor_pagination(records)
  else
    offset_pagination(records)
  end
end

def cursor_pagination(records)
  records.where("id < ?", params[:cursor])
         .order(id: :desc)
         .limit(per_page)
end
```

For now, offset is acceptable for admin panels. But ticket listing APIs should use cursor pagination.

---

### M5: `JsonResponse#serialize` uses `case` without exhaustive handling

**File**: `app/controllers/concerns/platform/json_response.rb:5-15`

```ruby
def serialize(data, options = {})
  case data
  when ActiveRecord::Base, ActiveRecord::Relation
    ActiveModelSerializers::SerializableResource.new(data, options).as_json
  when Hash
    serialize_hash(data, options)
  when Array
    data.map { |value| serialize(value, options) }
  else
    data  # ← Falls through silently
  end
end
```

The `else` branch returns raw data without serialization. If a developer passes an unexpected type (e.g., `ActiveModel::Errors`, `String`, `Integer`), it silently returns the raw value. This can cause API responses to have inconsistent formats.

**Fix**: Either raise on unexpected types or log a warning:
```ruby
def serialize(data, options = {})
  case data
  when ActiveRecord::Base, ActiveRecord::Relation
    ActiveModelSerializers::SerializableResource.new(data, options).as_json
  when Hash
    serialize_hash(data, options)
  when Array
    data.map { |value| serialize(value, options) }
  when NilClass
    nil
  else
    Rails.logger.warn "JsonResponse: unexpected data type #{data.class}, returning raw"
    data
  end
end
```

---

### M6: `PermissionRegistry` uses mutable class-level constant

**File**: `lib/platform/permission_registry.rb:3`

```ruby
REGISTRY = {} # rubocop:disable Style/MutableConstant
```

The comment acknowledges the issue but doesn't fix it. Mutable constants are not thread-safe. In a multi-threaded Puma server, concurrent calls to `register` could corrupt the registry.

**Fix**: Use a `Mutex` or `Concurrent::Map`:
```ruby
module Core
  class PermissionRegistry
    @registry = {}
    @mutex = Mutex.new

    class << self
      def register(namespace, &block)
        @mutex.synchronize do
          builder = RegistryBuilder.new(namespace.to_s)
          builder.instance_eval(&block)
          builder.persist!
          @registry[namespace.to_s] = builder.permissions
        end
      end

      def all_permissions
        @mutex.synchronize { @registry.values.flatten }
      end

      def for_namespace(namespace)
        @mutex.synchronize { @registry[namespace.to_s] || [] }
      end
    end
  end
end
```

---

## LOW ISSUES

### L1: `UserAuthenticatable` validates phone uniqueness with `allow_blank: true` but phone is required

**File**: `app/models/concerns/platform/user_authenticatable.rb:14-15`

```ruby
validates :phone, uniqueness: true, allow_blank: true
```

The `allow_blank: true` on the uniqueness validator means a blank phone passes the uniqueness check. But the `email_or_phone_present` validation requires at least one. This is logically correct but confusing — the uniqueness validation should not have `allow_blank: true` since phone is the primary identity anchor.

**Fix**: Remove `allow_blank: true` from phone uniqueness:
```ruby
validates :phone, uniqueness: { case_sensitive: false }, allow_nil: true
```

Or better, since phone is now the anchor (per architecture), make it required:
```ruby
validates :phone, presence: true, uniqueness: { case_sensitive: false }
```

---

### L2: `SoftDeletable` uses `scope :with_deleted, -> { all }` which is misleading

**File**: `app/models/concerns/platform/soft_deletable.rb:8`

```ruby
scope :kept, -> { where(deleted_at: nil) }
scope :only_deleted, -> { where.not(deleted_at: nil) }
scope :with_deleted, -> { all }
```

The `with_deleted` scope returns `all`, which means it returns both kept and deleted records. But the name suggests "include deleted records" — which is correct. However, there's no `default_scope` to exclude deleted records, so `with_deleted` is a no-op.

**Impact**: Developers who include this concern will expect `User.all` to exclude deleted records, but it won't. The concern provides scopes but doesn't enforce the default behavior.

**Fix**: Either add a `default_scope` or rename the scopes to be clearer:
```ruby
module Core
  module SoftDeletable
    extend ActiveSupport::Concern

    included do
      default_scope { where(deleted_at: nil) }
      scope :with_deleted, -> { unscope(where: :deleted_at) }
      scope :only_deleted, -> { with_deleted.where.not(deleted_at: nil) }
    end

    def soft_delete
      update(deleted_at: Time.current)
    end

    def restore
      update(deleted_at: nil)
    end

    def deleted?
      deleted_at.present?
    end
  end
end
```

**Warning**: Adding `default_scope` has significant implications (all queries must use `unscoped` to include deleted records). Only do this if you're confident about the tradeoff.

---

### L3: `RoleSerializer` includes all permissions — N+1 risk

**File**: `app/serializers/platform/role_serializer.rb:5`

```ruby
has_many :permissions, serializer: Core::PermissionSerializer
```

If the `UserAuthSerializer` includes roles, and each role includes permissions, this creates an N+1 query: 1 query for user → N queries for roles → N×M queries for permissions.

**Fix**: Ensure controllers use `.includes(roles: :permissions)` when serializing users:
```ruby
# In controllers:
def eager_loaded_associations
  %i[roles permissions]
end
```

Or use AMS's `include` directive to control depth:
```ruby
render_success(data: user, serializer_options: {
  include: ["roles", "roles.permissions"]
})
```

---

### L4: Test fixtures use hardcoded UUIDs — fragile and hard to maintain

**Files**: All `test/fixtures/core_*.yml` files

```yaml
super_admin:
  id: 11111111-1111-1111-1111-111111111111
```

Hardcoded UUIDs work but are fragile. If a test accidentally uses the wrong UUID, it silently creates a different record. They also make it hard to add new fixtures without checking for collisions.

**Fix**: Use ERB to generate UUIDs or use named references:
```yaml
super_admin:
  id: <%= SecureRandom.uuid %>
  email: superadmin@example.com
  phone: "+251911000001"
```

Or better, use factory_bot for dynamic test data and keep fixtures only for truly static data.

---

## ARCHITECTURAL OBSERVATIONS

### What's Done Well

1. **Concern composition is excellent** — `Authenticatable`, `Authorizable`, `Filterable`, `Pagination` are independent and composable. A controller can include any combination without conflicts.

2. **Error hierarchy is clean** — `Core::Error` → `Core::AuthenticationError` → `Core::AuditableRecordNotFoundError`. This allows granular rescue at any level.

3. **Result objects in `BaseService`** — Using `Result.success`/`Result.failure` instead of exceptions for expected failures is the right pattern.

4. **Audit system is comprehensive** — The snapshot-based audit with before/after diffing is production-grade. The DSL (`auditable associated: [:comments], only: [:status]`) is intuitive.

5. **Review workflow is flexible** — Multiple review contexts, configurable transitions, and feedback support make this suitable for complex approval workflows.

6. **Permission registry DSL** — The `register :namespace { resource :users, actions: %i[index create update] }` pattern is clean and self-documenting.

7. **Database schema is well-indexed** — Composite indexes, partial indexes (`where: "email IS NOT NULL"`), and proper foreign keys show good database design.

8. **UUID v7 for primary keys** — Using `gen_random_uuid_v7()` (time-ordered UUIDs) is excellent for performance — they're index-friendly and avoid the random-write penalty of UUID v4.

### What Needs Attention

1. **No configuration module** — Hardcoded values (`default_per_page = 25`, `max_per_page = 100`, `OTP_EXPIRY_MINUTES = 5`) are scattered across files. A `Core.configure` block would centralize these.

2. **No request tracking** — There's no `CurrentAttributes` or request ID propagation. Audit logs capture `request_uuid` but it's not propagated to background jobs or service objects.

3. **No rate limiting** — The auth endpoints (`login`, `signup`, `request_otp`) have no rate limiting. This is a security risk for brute-force attacks.

4. **No API versioning** — Routes are `/auth/login`, not `/api/v1/auth/login`. As the API evolves, versioning will be needed.

5. **Test coverage is thin** — Only `UserTest`, `TokenServiceTest`, and `CoreAuthTest` exist. The concerns (`Common`, `AuditableController`, `ReviewableController`, `Authorizable`) have no unit tests.

6. **No `# frozen_string_literal: true`** — As noted in M1, this is a performance and consistency issue.

---

## RECOMMENDED PRIORITY ORDER

### Immediate (Before Phase 2)
1. **C1**: Make `password_digest` nullable — blocks shadow user creation
2. **C2**: Remove `temp_password` column — dead code
3. **C3**: Fix refresh token rotation — prevents user lockout
4. **H5**: Fix `ApplicationPolicy` resource name — prevents silent auth failures
5. **M1**: Add `# frozen_string_literal: true` to all files — mechanical, low risk

### Short-term (Phase 2)
6. **H1**: Extract `AuditableController` into focused services
7. **H2**: Extract `AuditLoggerJob` business logic
8. **H3**: Extract `ReviewableController` state machine
9. **H4**: Use `UserRole.active` scope instead of raw SQL
10. **M3**: Narrow `Filterable` error handling
11. **M6**: Add thread safety to `PermissionRegistry`

### Medium-term (Phase 3+)
12. **M2**: Make `Common#set_object` lazy
13. **M4**: Add cursor-based pagination for ticket APIs
14. **M5**: Handle unexpected types in `JsonResponse`
15. **L1**: Clean up phone validation
16. **L2**: Decide on `default_scope` for `SoftDeletable`
17. **L3**: Fix N+1 in role/permission serialization
18. **L4**: Migrate fixtures to factory_bot

---

## SUMMARY

The Core framework is **80% of the way to world-class**. The architecture is sound, the concerns are composable, and the database schema is well-designed. The 18 issues identified here are fixable and mostly involve extracting responsibilities from oversized concerns, adding thread safety, and fixing a few critical data integrity issues.

**The biggest risk** is the `AuditableController` (507 lines) and `AuditLoggerJob` (312 lines) — these are the hardest to maintain and test. Extracting them into focused services will make the system significantly more maintainable.

**The biggest win** is fixing the 3 critical issues (C1, C2, C3) — they block core functionality and could cause production incidents.
