# PolicyMatrixTest — Spec

## Overview

A `Core::PolicyMatrixTest` concern that generates policy contract assertions (`Policy.new(user, record).action?`) for every user fixture × action combination. Evaluates the policy directly (no HTTP), using real fixture users from the database and record shapes that match what the controller would pass to `authorize`.

Shareable between standalone policy test files (`test/policies/...`) and integrated `Core::ResourceTest`. Designed for **standard nested resources** (one non-`User` parent association) with `record_builders:` override support for non-standard patterns.

## API

### Standalone — nested policy (parent_fixture required)

```ruby
class Organizations::MembershipPolicyTest < ActiveSupport::TestCase
  include Core::PolicyMatrixTest

  policy_matrix_test Organizations::MembershipPolicy,
    parent_fixture: :one
end
```

The `parent_fixture:` option provides the fixture key. The parent accessor (e.g. `organizations_organizations`) is inferred from the model's `belongs_to` associations — see [Parent inference heuristic](#parent-inference-heuristic). This works for **standard nested resources** (one non-`User` parent association). For models with multiple non-`User` parents, provide `parent_fixture:` but the fixture accessor may need a `record_builders:` override.

### Standalone — top-level policy (no parent)

```ruby
class Organizations::OrganizationPolicyTest < ActiveSupport::TestCase
  include Core::PolicyMatrixTest

  policy_matrix_test Organizations::OrganizationPolicy
end
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `parent_fixture` | Symbol | `nil` | Fixture key for parent record (e.g. `:one`). Required for standalone nested policies. When called from `resource_test`, resolved automatically from the controller's `parent_class`. |
| `model_class` | Class | Inferred from policy name | Explicit model when policy doesn't follow `ModelNamePolicy` convention. |
| `users` | Array of Symbols | All fixture keys from `core_users.yml` | Limit tested user types. |
| `actions` | Array of Symbols | `%i[index show create update destroy]` | Limit tested actions. |
| `record_builders` | Hash | `{}` (inferred) | Override per-action record construction. Keyed by action symbol, value is a proc executed in test instance context. |
| `scope` | Boolean | `false` | Generate scope include/exclude tests. Only works when the user provides `scope_expectations:`. See Scope section. |
| `scope_expectations` | Hash | `{}` | Per-user expected scope behavior. Required when `scope: true`. Keyed by fixture key symbol, value is `:includes` or `:excludes`. |

### Record builder overrides

```ruby
policy_matrix_test Organizations::MembershipPolicy,
  parent_fixture: :one,
  record_builders: {
    create: -> { @parent.memberships.new(user: core_users(:attendee), role: :member) },
    destroy: -> { @parent.memberships.create!(user: core_users(:attendee), role: :member) }
  }
```

### Scope tests (opt-in, explicit expectations only)

```ruby
policy_matrix_test Organizations::MembershipPolicy,
  parent_fixture: :one,
  scope: true,
  scope_expectations: {
    super_admin: :includes,
    core_admin: :excludes,
    attendee: :excludes
  }
```

Here `parent_fixture: :one` is owned by `super_admin`, so `core_admin` (who owns `:two`) is excluded. If the parent fixture were `:two`, the expectations would swap.

Without `scope_expectations:`, no scope tests are generated. Scope logic depends on specific data setup and can't be inferred from action policy methods.

## What it generates

For a 5-action policy with 3 fixture users (`super_admin`, `core_admin`, `attendee`) and no scope, with `parent_fixture: :one` (owned by `super_admin`):

```ruby
# Policy contract tests (action × user)
test "index? permits super_admin" do
  assert MembershipPolicy.new(core_users(:super_admin), record_for(:index)).index?
end

test "index? denies core_admin" do
  assert_not MembershipPolicy.new(core_users(:core_admin), record_for(:index)).index?
end

test "index? denies attendee" do
  assert_not MembershipPolicy.new(core_users(:attendee), record_for(:index)).index?
end

test "show? permits super_admin" do ...
test "show? denies core_admin" do ...
test "show? denies attendee" do ...
test "create? permits super_admin" do ...
test "create? denies core_admin" do ...
test "create? denies attendee" do ...
test "update? permits super_admin" do ...
test "update? denies core_admin" do ...
test "update? denies attendee" do ...
test "destroy? permits super_admin" do ...
test "destroy? denies core_admin" do ...
test "destroy? denies attendee" do ...
```

Count: 15 tests (5 actions × 3 users). No scope tests by default. Owner fixture keys (`super_admin`) get `permits`; non-owner keys (`core_admin`, `attendee`) get `denies`. With a different parent fixture (e.g. `parent_fixture: :two`, owned by `core_admin`), the roles would swap.

With `scope: true` and `scope_expectations:`:
```
+3 scope tests
= 18 total
```

The helper provides a `record_for(action)` accessor that returns the appropriate record per action:

```ruby
def record_for(action)
  mc = self.class.instance_variable_get(:@model_class)
  child_assoc = self.class.child_association

  case action
  when :index, :create then @parent&.public_send(child_assoc)&.new || mc.new
  when :show, :update, :destroy then @saved_child || mc.first || mc.new
  end
end
```

The model class and child association are accessed via the test class at runtime because `@model_class` is a class instance variable (set by the macro) and `child_association` is a class method — both invisible to bare `@` access in an instance method.

Generated tests use this to avoid repeating the record resolution logic in every assertion.

### Test naming

Pattern: `"{action}? {permits,denies} {fixture_key}"`

- `permits` when the policy returns `true`
- `denies` when the policy returns `false`
- `{action}?` matches the actual policy method name

Scope suffix: `"scope {includes,excludes} record for {fixture_key}"`

## User resolution

`policy_matrix_test` uses **real fixture users loaded from the database** via `core_users(fixture_key)`, not `MockUser`. This ensures:

- `user.id` works (needed by policies that query `Membership.exists?(user_id: user.id)`)
- `user.super_admin?` returns the correct value
- `user.has_role?("CODE")` returns the correct value
- All methods the policy calls on `user` behave as they would in production

`Core::ResourceTest` continues to use `MockUser` for class-load-time integration expectations (response codes). `policy_matrix_test` uses real users at test runtime for contract assertions. Two independent code paths sharing fixture infrastructure. The runtime tests catch any discrepancies between MockUser approximations and real user behavior.

## Record inference

The macro generates a `setup` block that runs at test runtime. It captures some locals from the closure at class-definition time and calls runtime helpers for the rest:

```ruby
setup do
  if _parent_fixture_accessor
    @parent = public_send(_parent_fixture_accessor, _parent_fixture_key)
    @saved_child = @parent.public_send(_child_assoc).first
    @saved_child ||= @parent.public_send(_child_assoc).create!(compute_minimal_saved_attrs(_model_class))
  end
end
```

The locals are captured from the macro's closure (class-definition time, must not touch DB):

```ruby
_parent_fixture_key        = @options[:parent_fixture]
_parent_fixture_accessor   = resolve_parent_fixture_accessor
_child_assoc               = child_association
_model_class               = @model_class   # class instance variable from the macro
```

`compute_minimal_saved_attrs` is called inside the setup block, not captured — it runs at **test runtime** when `core_users(:attendee)` is available.

When `parent_fixture` is nil (top-level resource), `_parent_fixture_accessor` is nil, the condition is false, no setup runs, and `record_for` falls through to `model_class.first || model_class.new`.

#### Parent inference heuristic (standard nested resources)

The parent fixture accessor is inferred from the model's `belongs_to` associations by taking the first non-`Core::User` association. This works for the **standard pattern** (one non-`User` belongs_to). This method runs at class-definition time (called from the macro), so `@model_class` and `@options` are class instance variables visible in class-method scope:

```ruby
def resolve_parent_fixture_accessor
  return nil unless @options[:parent_fixture]

  non_user_parent = @model_class.reflect_on_all_associations(:belongs_to)
    .reject { |a| a.klass == Core::User }
    .first

  non_user_parent&.klass&.model_name&.route_key
end
```

For `Organizations::Membership`:
| Association | klass | Result |
|-------------|-------|--------|
| `belongs_to :user` | `Core::User` | Rejected |
| `belongs_to :organization` | `Organizations::Organization` | Kept → route_key `"organizations_organizations"` ✓ |

**Limitations:** This heuristic assumes the nested resource has exactly one `belongs_to` that isn't `Core::User`. Models with multiple non-user parents (e.g. `belongs_to :event` + `belongs_to :organization`) may resolve the wrong accessor. If inference produces the wrong parent, the setup block will fail to load a parent (wrong fixture class) or create child records through the wrong association. Fix with `record_builders:` override or an explicit `record:` proc.

`child_association` is inferred at class-load time:

```ruby
def child_association
  if respond_to?(:controller_class) && controller_class.respond_to?(:parent_association)
    controller_class.parent_association
  else
    @model_class.model_name.plural.to_sym
  end
end
```

When called from `resource_test` (integrated mode), the controller's `parent_association` class attribute is checked first. `resource_test` sets `controller_class` on the test class before invoking `policy_matrix_test` internally, so the concern has access to it. For standalone `policy_matrix_test` usage, there's no controller, so the helper falls back to `@model_class.model_name.plural.to_sym`.

### With `parent_fixture:`

| Action | Record |
|--------|--------|
| `index` | `@parent.public_send(child_association).new` |
| `create` | `@parent.public_send(child_association).new` |
| `show` | `@saved_child` |
| `update` | `@saved_child` |
| `destroy` | `@saved_child` |

### Without `parent_fixture:`

| Action | Record |
|--------|--------|
| `index` | `model_class.new` |
| `create` | `model_class.new` |
| `show` | `model_class.first || model_class.new` |
| `update` | `model_class.first || model_class.new` |
| `destroy` | `model_class.first || model_class.new` |

If `model_class.first` returns nil (no records exist), falls back to `model_class.new`. The nil case is visible at test runtime — the unsaved record will likely fail the policy call, and the test error points the developer to add a fixture or record builder.

### Required attribute filling — unsaved records for index/create policy

For `index?` and `create?` policy evaluation, the record is built via `@parent.public_send(child_association).new` with no arguments. The unsaved record has nil FKs — this is safe because policy predicates typically check the `user` argument, not nil FK columns. If the policy errors on nil FK, the test fails with the actual error, prompting a `record_builders:` override.

The `record_for(:create)` path intentionally avoids filling attributes because:
- No DB is available at the time the closure is built (class-definition time)
- Policy evaluation cares about user authorization, not model validity
- Any attributes the policy needs can be set via `record_builders:`

This differs from `Core::ResourceTest`'s `resolve_default_create_attrs`, which fills non-parent FKs with real user IDs. The integration test needs valid model attributes to persist via POST → controller → `create!`. The policy test evaluates in-memory records where nil FKs are harmless. The two code paths match their contexts: HTTP validity for integration, authorization logic for policy.

### `compute_minimal_saved_attrs` — saved record for setup block

The setup block creates a saved child record at test runtime for `show`/`update`/`destroy` tests. This uses `defined_enums` and `reflect_on_association` (not fixture YAML, avoiding unresolved reference strings):

```ruby
def compute_minimal_saved_attrs(model_class)
  attrs = {}

  model_class.defined_enums.each do |col, mapping|
    attrs[col] = mapping.keys.find { |k| k != "owner" } || mapping.keys.first
  end

  model_class.reflect_on_all_associations(:belongs_to).each do |ref|
    next if ref.polymorphic?
    next if ref == non_user_parent_association(model_class)

    if ref.klass == Core::User
      attrs[ref.foreign_key] = non_owner_user.id
    end
  end

  attrs
end
```

- Core::User FKs → set to `non_owner_user.id` (the only FK we can safely auto-fill without knowing the schema)
- Parent FK → omitted — `create!` through association sets it automatically
- Other FKs → left blank — if required, `create!` fails at setup, developer adds `record_builders:` override

`non_owner_user` and `non_user_parent_association` are concern helpers (`model_class` is passed from the closure, avoiding the class-vs-instance variable trap):

```ruby
def non_owner_user
  core_users(:attendee)
end

def non_user_parent_association(model_class)
  model_class.reflect_on_all_associations(:belongs_to)
    .reject { |a| a.klass == Core::User }
    .first
end
```

If the setup block can't create the record, the test fails at setup with the creation error, and the developer adds `record_builders:` overrides for `show`/`update`/`destroy`.

## Scope tests (opt-in only)

Scope tests are **not auto-generated**. They require explicit `scope_expectations:` because:

- Scope correctness depends on specific data setup (which records belong to which user)
- The helper cannot determine which users should `includes` vs `excludes` without running the scope itself (circular) or knowing the policy's scope logic
- `show?` is an unreliable heuristic — a policy might allow `show?` for a user whose scope excludes the record

When scope tests are requested:

```ruby
policy_matrix_test Organizations::MembershipPolicy,
  parent_fixture: :one,
  scope: true,
  scope_expectations: {
    super_admin: :includes,
    core_admin: :excludes,
    attendee: :excludes
  }
```

With `parent_fixture: :one` (owned by `super_admin`), only the org owner sees the record in scope:

```ruby
# define_method creates an instance method where self is the test instance,
# so @saved_child (set in setup) is found correctly. mc captures @model_class
# from the class context as a plain local.
mc = @model_class
define_method(:scope_record) do
  @saved_child || mc.first
end

test "scope includes record for super_admin" do
  scope = MembershipPolicy::Scope.new(core_users(:super_admin), Membership)
  assert_includes scope.resolve, scope_record
end

test "scope excludes record for core_admin" do
  scope = MembershipPolicy::Scope.new(core_users(:core_admin), Membership)
  refute_includes scope.resolve, scope_record
end

test "scope excludes record for attendee" do
  scope = MembershipPolicy::Scope.new(core_users(:attendee), Membership)
  refute_includes scope.resolve, scope_record
end
```

## Integration with `Core::ResourceTest` (planned)

The proposed integration makes `Core::ResourceTest` call `policy_matrix_test` when `resource_test` is declared with `policy_contract: true` (default). The user writes only:

```ruby
class Organizations::MembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test parent_fixture: :one
  # → CRUD integration tests (HTTP responses, uses MockUser at class-load time)
  # → Policy contract tests (Policy.new assertions, uses real DB users at test runtime)
  # → Both from one declaration
end
```

**Current (resource_test.rb):** Neither `include Core::PolicyMatrixTest` nor the `policy_matrix_test` call exists yet. Integration tests use `resolve_policy_results` with `record = @model_class.new` for every action (see [Nested CRUD spec sec. 3](../RESOURCE_TEST_NESTED_CRUD_SPEC.md#3-nested-policy-context-at-class-load-time-fixes-policy-expectation-matrix)). All actions are evaluated against MockUser.

**Planned changes to `resource_test.rb`:**

1. Include `Core::PolicyMatrixTest` in its `included do` block so `policy_matrix_test` is available as a class method.
2. Call `policy_matrix_test` at the end of the `resource_test` macro with resolved data. Before the call, expose the controller class so the concern can access `parent_association`:

```ruby
# Inside resource_test's Metadata, after build (proposed addition):
controller_class_value = @controller_class
test_class.define_method(:controller_class) { controller_class_value }
actions = %i[index show create update destroy] - @options[:except]
policy_matrix_test @policy_class,
  parent_fixture: @options[:parent_fixture],
  actions: actions
```

After the change, the two code paths would be:
- **Integration expectations**: `resolve_policy_results` at class-load time with MockUser. Conservative — `rescue false` on any error. Sets expected response codes (2xx vs 403).
- **Policy contract assertions**: `policy_matrix_test` at test runtime with real DB users. Precise — asserts the actual policy result. Catches any MockUser discrepancies.

When proposed integration is complete, opt out via:

```ruby
resource_test policy_contract: false
```

Until then, standalone policy test files (`test/policies/...`) include `Core::PolicyMatrixTest` explicitly, same as now.

## What stays manual

| Category | Why |
|----------|-----|
| **Scope assertions** | Need explicit expectations — helper can't infer includes vs excludes without circular reasoning. Opt-in with `scope_expectations:`. |
| **Side-effect tests** | `after_create_hook` creates Owner membership, sends emails, etc. Domain logic, not policy logic. |
| **Business invariants** | "Only one owner per org", "can't change role to owner if already exists". |
| **Custom response shape** | JSON structure, custom headers, pagination shape. |
| **Non-CRUD actions** | Custom controller actions (e.g. `PATCH /transfer_ownership`). |
| **Role-specific visibility** | Different users see different response attributes. Handled by serializer_profile + VISIBILITY, not policy action methods. |

## Edge cases

### SKIP_AUTHORIZE actions

When the controller skips authorization for certain actions, `policy_matrix_test` skips those actions. If called standalone (no controller context), use `actions:` to exclude them manually.

### Policy errors on nil FK

When `record.organization&.owner` is called on a new record without `organization_id`, the policy returns `nil`. A `nil` return from a predicate is treated as falsy — the test passes with `assert_not`. This matches controller behavior: a record without a parent would fail before reaching the policy in `set_parent`.

### Scope with no saved records

If no records exist for the resource, `scope.resolve` returns an empty relation. The helper creates a saved child during setup to avoid this.

### Non-standard model name patterns

The helper resolves the model class from the policy class name: `Organizations::MembershipPolicy` → `Organizations::Membership`. If the policy doesn't follow the `Policy` suffix convention, pass `model_class:` explicitly:

```ruby
policy_matrix_test MyCustomPolicy,
  model_class: Organizations::Membership
```

## Files involved

| File | Role |
|------|------|
| `test/support/core/policy_matrix_test.rb` | New — the concern implementation |
| `test/support/core/resource_test.rb` | Updated — calls `policy_matrix_test` internally |
| `test/policies/organizations/membership_policy_test.rb` | Updated — uses `policy_matrix_test` instead of manual action tests |
| `test/policies/organizations/organization_policy_test.rb` | Updated — uses `policy_matrix_test` instead of manual action tests |

## Migration path

### Before (manual policy test, 81 lines)

```ruby
class Organizations::MembershipPolicyTest < ActiveSupport::TestCase
  setup do
    @org = Organizations::Organization.create!(name: "Test Org")
    @owner = core_users(:super_admin)
    @org.memberships.create!(user: @owner, role: :owner)
    @non_owner = core_users(:attendee)
    @super_admin = core_users(:super_admin)
    @membership = @org.memberships.create!(user: @non_owner, role: :member)
  end

  test "index? permits org owner" do
    assert Organizations::MembershipPolicy.new(@owner, @org.memberships.new).index?
  end
  # ... 15 more action tests + 3 scope tests
end
```

### After (auto-generated, 20 lines)

```ruby
class Organizations::MembershipPolicyTest < ActiveSupport::TestCase
  include Core::PolicyMatrixTest

  policy_matrix_test Organizations::MembershipPolicy,
    parent_fixture: :one

  test "scope returns all for super_admin" do
    scope = Organizations::MembershipPolicy::Scope.new(core_users(:super_admin), Organizations::Membership)
    assert_includes scope.resolve, organizations_organizations(:one).memberships.first
  end

  test "scope returns only owned org memberships for non-admin" do
    scope = Organizations::MembershipPolicy::Scope.new(core_users(:attendee), Organizations::Membership)
    assert_not_includes scope.resolve, organizations_organizations(:one).memberships.first
  end

  test "scope returns owned org memberships for owner" do
    scope = Organizations::MembershipPolicy::Scope.new(core_users(:super_admin), Organizations::Membership)
    assert_includes scope.resolve, organizations_organizations(:one).memberships.first
  end
end
```

Status: **15 generated action tests + 3 manual scope tests = 18 total. 81 → 20 lines.**

### Integration test

```ruby
class Organizations::MembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test parent_fixture: :one
  # → CRUD integration tests (15+ tests, uses MockUser)
  # → Policy contract tests (15 tests, uses real users)

  # Only manual tests for things resource_test can't infer:
  test "non-owner cannot list memberships via scope" do
    get path, headers: token_headers_for(core_users(:attendee)), as: :json
    assert_response :forbidden
  end
end
```
