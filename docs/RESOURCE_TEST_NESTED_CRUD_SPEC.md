# ResourceTest Nested CRUD Support — Spec

## Goal

Make `resource_test` provide **zero-config baseline integration coverage for standard nested resources** (e.g. `Organizations::Memberships`) the same way it already works for top-level resources (e.g. `Organizations::Organizations`). "Standard" means a single non-`User` parent association and a single child association inferred from the controller — the common one-belongs-to-many-to-many pattern. "Baseline" means all CRUD actions get integration tests that verify the controller handles the request without error, but full HTTP response precision for show/update/destroy requires the separate `policy_matrix_test` contract layer — see [Trade-off](#blind-spot--weak-assertions-cannot-detect-controller-layer-before_action-guards).

## What changes

### 1. Nested path inference (replaces hardcoded path)

**Before:** `memberships_test.rb` hardcodes the org UUID:
```ruby
resource_test path: "/organizations/organizations/019e5f69-d922-75a3-b880-be8f75b18ad0/memberships"
```

**After:** Inferred from the controller:
```ruby
resource_test
```

**Logic** (in `Metadata.resolve_path`):

The controller declares at class level (from `Core::Common`):
```ruby
class Organizations::MembershipsController
  self.model_class = Organizations::Membership
  self.parent_class = Organizations::Organization
  self.parent_param = :organization_id
  self.parent_association = :memberships
end
```

`Metadata` detects `parent_class` is set, then builds a path template as a lambda:

```ruby
def build_nested_path
  namespace = controller_namespace
  parent_route = @controller_class.parent_class.model_name.plural
  child_route = @controller_class.model_class.model_name.plural

  -> { "#{namespace}/#{parent_route}/#{@parent.id}/#{child_route}" }
end

def controller_namespace
  parts = @controller_class.name.underscore.split("/")
  parts.length > 1 ? "/#{parts[0..-2].join("/")}" : ""
end
```

The lambda captures nothing at definition time — it resolves `@parent.id` at test runtime via `instance_exec` (which `resolve_path_for` already does for callable paths). `@parent` is set in a generated `setup` block.

For unnamespaced controllers (e.g. `MembershipsController`), `controller_namespace` returns `""`, producing path `"/organizations/:id/memberships"`. If the route differs, override with `path:`.

Result path: `/organizations/organizations/019e5f69-.../memberships`

### 2. Parent fixture + child record inference (replaces `record:`)

**Before:**
```ruby
resource_test record: -> { Organizations::Membership.first }
```

**After:** Auto-inferred.

When `parent_class` is detected, `Metadata` auto-sets `parent_fixture` to `:one` (overridable). During `Metadata.build`, the method `register_setup_block` generates a setup block and adds it to the test class:

```ruby
def register_setup_block(test_class)
  parent_fixture_key = @options[:parent_fixture] || :one
  child_assoc = child_association
  parent_route_key = @controller_class.parent_class.model_name.route_key
  mc = @model_class
  pp = @controller_class.parent_param

  test_class.setup do
    @parent = public_send(parent_route_key, parent_fixture_key)
    @child_record = @parent.public_send(child_assoc).first
    @child_record ||= @parent.public_send(child_assoc).create!(minimal_saved_attrs(mc, pp))
  end
end
```

`test_class.setup` is available because `Metadata` runs inside `class_methods` context within `included do...end`. The block is registered at class-definition time but executes at test runtime, when fixture accessors and the database are available. The `mc` and `pp` locals are captured from Metadata at class-definition time; `minimal_saved_attrs` is a concern method called at test runtime.

Then uses these in generated tests:

| Action | Record |
|--------|--------|
| `show` | `@child_record` |
| `update` | `@child_record` |
| `destroy` | `@child_record` |
| `create` | `nil` (creates a new one via params) |

The ID from `@child_record` is interpolated into the nested path for HTTP requests.

### 3. Nested policy context at class-load time (proposed fix for policy expectation matrix)

**Current code:** `Metadata.resolve_policy_results` (`resource_test.rb:346`) uses `record = @model_class.new` for **every action** — both index/create AND show/update/destroy. For nested resources, all actions get `organization_id = nil`, meaning any policy that checks `record.organization_id` or `record.organization&.owner` produces `nil` → falsy → expected 403. When the runtime record has a real parent FK, `show?`/`update?`/`destroy?` evaluate correctly and return 200 — creating a test failure (expected 403, got 200).

**The bug:** For `index?`/`create?`, a policy that relies on parent context (`record.organization_id.present?`) gives wrong results at class-load time because the record has `nil` parent FK.

**Proposed approach to `Metadata`:** At class-load time, read the parent fixture YAML directly (not via DB — same pattern as `load_fixture_data`), build an unsaved parent AR record from the attributes, then construct child records through it. This fixes index/create. Show/update/destroy remain approximated (unsaved child → `rescue false` → forbidden) — see [Weak assertions limitation](#blind-spot--weak-assertions-cannot-detect-controller-layer-before_action-guards).

```ruby
def policy_record_for(action, parent)
  return @model_class.new if parent.nil?

  case action
  when :index, :create
    parent.public_send(child_association).new
  when :show, :update, :destroy
    parent.public_send(child_association).first ||
      parent.public_send(child_association).new
  end
end

def load_parent_fixture_for_policy
  fixture_key = @options[:parent_fixture] || :one
  # Fixture filenames use route_key (namespaced underscore path), not model_name.plural
  # e.g. Organizations::Organization → organizations_organizations.yml
  fixture_path = Rails.root.join(
    "test/fixtures/#{@controller_class.parent_class.model_name.route_key}.yml"
  )
  raw = File.read(fixture_path)
  yaml = raw.include?('<%') ? ERB.new(raw, trim_mode: "-").result(binding) : raw
  attrs = YAML.safe_load(yaml)
            .select { |k, v| v.is_a?(Hash) && k.to_s == fixture_key.to_s }
            .values
            .first
  return nil unless attrs

  @controller_class.parent_class.new(attrs)
end
```

`ERB.new(..., trim_mode: "-").result(binding)` handles Rails fixture ERB (`<%= %>`, `<%-` trim) the same way `ActiveRecord::FixtureSet` does internally. The guard `raw.include?('<%')` skips ERB processing for plain YAML files. No special permitted classes needed — fixture attribute values are plain scalars (strings, numbers, booleans).

**Limitation — show/update/destroy integration tests use weak assertions for nested resources:** At class-load time, the test database is empty. For `show?`/`update?`/`destroy?`, the child record is unsaved (`parent.association.new`) — traversing `record.organization&.owner` will yield `nil` because the association loads from DB. The `rescue false` fallback in `resolve_policy_results` handles this by treating errors as forbidden. If used to generate integration test assertions, this would produce 403 expectations against a real 200 — a test failure.

**Resolution:** For nested resources, the class-load-time `resolve_policy_results` only determines integration test assertions for `index` and `create` (which are correct after the parent-scoping fix). For `show`/`update`/`destroy`, the integration tests are still generated but use **weak assertions** (verify no server error, e.g. `assert_not response.server_error?`). The runtime `policy_matrix_test` evaluates the policy against real saved records and generates `Policy.new(user, record).action?` assertions.

| Action | Class-load-time integration assertion | Runtime check |
|--------|---------------------------------------|---------------|
| `index` | Strong (correct — parent-scoped) | `policy_matrix_test` |
| `create` | Strong (correct — parent-scoped) | `policy_matrix_test` |
| `show` | Weak (no crash) | `policy_matrix_test` |
| `update` | Weak (same) | `policy_matrix_test` |
| `destroy` | Weak (same) | `policy_matrix_test` |

**Blind spot — weak assertions cannot detect controller-layer `before_action` guards.** The runtime `policy_matrix_test` checks the policy method (`Policy.new(user, record).show?`), which is necessary but not sufficient for the HTTP response contract. A controller can return 403 or 404 in a `before_action` before reaching the policy, or can override the policy result with a custom response. `assert_not response.server_error?` passes for 403, 404, 200, 302 — any non-5xx response. This means:

- A `before_action` that returns 403 for a user who would pass the policy → integration test passes ("no crash"), policy_matrix_test passes ("permits"), but real behavior is forbidden. **Neither test catches it.**
- A controller that returns 200 despite a `deny!` → integration test passes ("no crash"), policy_matrix_test reports "permits" (policy value, not actual response), but the response contradicts the policy. The gap is narrower — policy_matrix_test still catches the policy intent — but the HTTP assertion is unreliable.

**Mitigation:** For nested resources where show/update/destroy authorization relies on controller-layer guards (e.g. `require_admin!` before `authorize`), add focused manual integration tests:
```ruby
test "non-owner cannot show someone else's membership" do
  get organization_membership_path(@parent, @child_record),
    headers: token_headers_for(core_users(:attendee)),
    as: :json
  assert_response :forbidden
end
```
This pattern applies when the authorization boundary depends on middleware, `before_action`, or response shape — anything beyond the pure policy method the contract verifies.

Trade-off: standard nested resources get zero-config **baseline** integration coverage (all CRUD actions, all user fixtures, no crash), but show/update/destroy HTTP assertion precision is limited when the authorization path includes controller-layer guards. Index/create assertions are fully precise because the parent-scoped evaluation at class-load time matches the runtime policy result. Full HTTP response precision for show/update/destroy relies on the `policy_matrix_test` contract layer — which verifies the policy method, not the controller's `before_action` guards.

**YAML reference limitation:** Fixture files use Rails cross-references like `user: owner_one`, `organization: one`. When read with `YAML.safe_load_file` at class-load time, these resolve to the literal strings `"owner_one"`, `"one"` — not UUIDs. The `policy_record_for` method accepts this: the unsaved record has nil FK values, which is safe for policy predicates (nil org ID → nil org → nil owner → `nil` as predicate → falsy). For the setup block's `create!`, this limitation is why `minimal_saved_attrs` computes attributes at runtime using `defined_enums` and `reflect_on_association` instead of reading YAML.


**What improves with this change:** `index?` and `create?` evaluations are now correct for nested policies because `parent.memberships.new` sets the parent FK. Previously they used `model_class.new` which had `organization_id = nil`.

| Action | Before (model_class.new) | After (parent-scoped) |
|--------|--------------------------|-----------------------|
| `index` | organization_id = nil → forbidden | organization_id = fixture UUID → correct |
| `create` | organization_id = nil → forbidden | organization_id = fixture UUID → correct |
| `show` | organization_id = nil → forbidden | Still unsaved → `rescue false` → forbidden (approximation) |
| `update` | same | same |
| `destroy` | same | same |

### 4. Create param inference for nested resources (controller POST params)

**Before:** `memberships_test.rb` passes `organization_id` in params:
```ruby
create_params: -> {
  { membership: { user_id: core_users(:attendee).id, role: "member",
                   organization_id: organizations_organizations(:one).id } }
}
```

**After:** `organization_id` is no longer needed because `Core::Common#create` builds through the parent (line 52-53):

```ruby
object = if self.class.parent_class
  @parent.public_send(child_association).new(model_params)
else
  @clazz.new(model_params)
end
```

The helper auto-injects the parent FK. The auto-detected params for the HTTP POST body are built at class-load time and work for nested resources with:

| Field | Strategy | Source |
|-------|----------|--------|
| Parent FK (`organization_id`) | Excluded — controller builds through parent | N/A |
| Enum columns (`role`) | Pick first enum value that isn't `:owner` | `defined_enums` |
| String columns (`name`) | Use fixture value (add random suffix for uniqueness) | Fixture YAML (plain strings, no references) |
| Core::User FKs (`user_id`) | Pick first non-owner fixture user ID (e.g. `:attendee`) | Fixture YAML `id` field read at class-load time (same ERB-safe `ERB.new(...).result` then `YAML.safe_load` pattern as `load_parent_fixture_for_policy`) |
| JSON/JSONB columns | Use fixture value | Fixture YAML |
| Other FKs (e.g. `event_id`) | Not auto-filled. If required, the controller returns validation error → developer adds `create_params:` override. | N/A |

The `organization_id` is excluded from POST params because `Core::Common#create` calls `@parent.public_send(child_association).new(model_params)`, which sets the parent FK from the association.

Core::User FK IDs are read from `core_users.yml` fixture YAML at class-load time (the `id` field is a literal UUID in the fixture file). Fixture accessors like `core_users(:attendee).id` are not available at class-load time — the YAML is read directly, same ERB-safe pattern as `load_parent_fixture_for_policy`. The `core_users` fixture YAML always specifies explicit `id` values (by Rails convention), so extracting `["attendee"]["id"]` from the parsed YAML is reliable.

#### 4a. `minimal_saved_attrs` — setup block's saved record (runtime)

The setup block needs to create a saved child record at **test runtime** (for show/update/destroy tests). This is separate from the controller POST params above.

`register_setup_block` captures `model_class` and `parent_param` from Metadata into the closure, then the setup block passes them to `minimal_saved_attrs` (defined on the concern, available to all test instances):

```ruby
def register_setup_block(test_class)
  parent_fixture_key = @options[:parent_fixture] || :one
  child_assoc = child_association
  parent_route_key = @controller_class.parent_class.model_name.route_key
  mc = @model_class
  pp = @controller_class.parent_param

  test_class.setup do
    @parent = public_send(parent_route_key, parent_fixture_key)
    @child_record = @parent.public_send(child_assoc).first
    @child_record ||= @parent.public_send(child_assoc).create!(minimal_saved_attrs(mc, pp))
  end
end
```

`minimal_saved_attrs` uses `defined_enums` and `reflect_on_association` (not fixture YAML, avoiding unresolved reference strings):

```ruby
def minimal_saved_attrs(model_class, parent_param)
  attrs = {}

  model_class.defined_enums.each do |col, mapping|
    attrs[col] = mapping.keys.find { |k| k != "owner" } || mapping.keys.first
  end

  model_class.reflect_on_all_associations(:belongs_to).each do |ref|
    next if ref.polymorphic?
    next if ref.foreign_key.to_s == parent_param.to_s
    next unless ref.klass == Core::User
    attrs[ref.foreign_key] = non_owner_user.id
  end

  attrs
end
```

Parent FK columns are intentionally omitted — `create!` is called through the parent association (`@parent.memberships.create!(attrs)`), which sets the parent FK automatically. Non-`Core::User` FKs are left blank — if the column is required, `create!` fails with a constraint error at setup time, and the developer adds `record_builders:` or `create_params:` override.

The `non_owner_user` helper is defined on the concern (same level as `minimal_saved_attrs`):

```ruby
def non_owner_user
  core_users(:attendee)
end
```

### 5. Update param inference for enum columns

**Before:**
```ruby
update_params: ->(record) { { membership: { role: "member" } } }
```

**After:** Auto-inferred:

```ruby
def resolve_default_update_attrs(record)
  return if @update_params_proc

  params = {}
  @model_class.defined_enums.each do |column, mapping|
    current = record.public_send(column)
    alternative = mapping.keys.find { |k| k != current }
    params[column] = alternative if alternative
  end

  return { @param_key => params } if params.any?

  # Fallback for non-enum models
  if @model_class.column_names.include?("name")
    { @param_key => { "name" => "Updated #{record.name}" } }
  end
end
```

For non-enum models without a `name` column, returns `nil` — the test will fail with a missing params error and the developer adds `update_params:`.

### 6. Option set

New option:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `parent_fixture` | Symbol | `nil` (auto-set to `:one` when `parent_class` detected) | Fixture key for parent record. |

Complete set:

```ruby
resource_test(
  except: [],
  path: nil,                       # Override path. Skipped when parent_class detected.
  parent_fixture: nil,             # Auto-set to :one when parent_class is present.
  model: nil,                      # Override model class.
  record: nil,                     # Override record. Not needed for nested — uses @child_record.
  create_params: nil,              # Override for complex associations.
  update_params: nil,              # Override. Not needed for enum models.
  policy_contract: true,           # Generate policy contract tests.
  skip_authorization: false,
  check_attributes: {},
  index: {}
)
```

### 7. `resolve_record` — updated for nested

```ruby
def resolve_record(action, meta)
  return meta.record_proc.call if meta.record_proc
  return @child_record if @child_record && %i[show update destroy].include?(action)
  return meta.model_class.first if %i[show update destroy].include?(action)
  nil
end
```

The `@child_record` check comes first, falling back to `model_class.first` for top-level resources.

### 8. `child_association` — delegates to controller

The helper resolves the child association name with the same logic as `Core::Common#child_association`: defaults to `@model_class.model_name.plural.to_sym`. No delegation required — it's a one-liner:

```ruby
def child_association
  @controller_class.parent_association || @model_class.model_name.plural.to_sym
end
```

This mirrors the controller's `child_association` (line 138: `self.class.parent_association || @clazz.model_name.plural.to_sym`) without instantiating a controller object or calling private methods.

### 9. End state comparison

**Top-level resource (unchanged):**
```ruby
class OrganizationsOrganizationsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test
end
```

**Nested resource (standard pattern, zero-config baseline):**
```ruby
class OrganizationsMembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test
end
```

**Nested resource with overrides:**
```ruby
class OrganizationsMembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test(
    parent_fixture: :two,
    create_params: -> { { membership: { user_id: core_users(:vip).id, role: "member" } } }
  )
end
```

### 10. Backward compatibility

| Scenario | Behavior | Config needed? |
|----------|----------|----------------|
| Top-level resource | Same as today | Zero |
| Nested resource, default fixture | Path, record, params, policy all inferred | Zero |
| Nested resource, custom fixture | Same, different parent | `parent_fixture: :two` |
| Nested resource, complex FKs | Path/record inferred, params need override | `create_params:` |
| Manual path override | `path:` checked first, skips inference | No change |
| Unnamespaced controller (no module) | Path inferred without namespace prefix | Verify path override if misrouted |

No existing test breaks. New inference activates only when `controller.parent_class.present?`.

### 11. Implementation order

1. `Metadata.resolve_path` — detect `parent_class`, build nested path lambda
2. `Metadata.register_setup_block` — register `setup` block with `@parent` and `@child_record`
3. `Metadata.resolve_policy_results` — use `policy_record_for(action, parent)` loaded from fixture YAML
4. `resolve_default_create_attrs` — inject parent FK, infer `user_id`, enums
5. `resolve_default_update_attrs` — detect enums, cycle values
6. `resolve_record` — prefer `@child_record` when present
7. Wire `parent_fixture:` option through `Metadata` pipeline
8. Integrate `PolicyMatrixTest` call under `policy_contract: true`
