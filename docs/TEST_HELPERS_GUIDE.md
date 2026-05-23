# Test Support Modules Guide

## Overview

The `test/support/core/` directory contains reusable Minitest support modules that eliminate boilerplate across integration tests for controllers using `Core::Common`. Instead of duplicating auth setup, CRUD assertions, pagination checks, and audit verifications in every domain test, include the relevant module and call the provided assertion helpers.

## Table of Contents

- [Installation / Setup](#installation--setup)
- [How It Works](#how-it-works)
- [Core::ResourceTest](#coreresourcetest)
- [Core::AuthTestHelpers](#coreauthtesthelpers)
- [Core::AuthorizationTestHelpers](#coreauthorizationtesthelpers)
- [Core::CrudTestHelpers](#corecrudtesthelpers)
- [Core::PaginationTestHelpers](#corepaginationtesthelpers)
- [Core::AuditTestHelpers](#coreaudittesthelpers)
- [Core::SlugableTest](#coreslugabletest)
- [Complete Example](#complete-example)
- [Migrating an Existing Test](#migrating-an-existing-test)
- [Adding a New Module](#adding-a-new-module)

---

## Installation / Setup

The support files are auto-loaded — no manual require is needed. This line in `test_helper.rb` handles it:

```ruby
Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }
```

To use the helpers, include `Core::ResourceTest` and call `resource_test`:

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test  # generates ~36 tests automatically
end
```

Or include individual helpers if you need only specific ones:

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers
  include Core::CrudTestHelpers
  include Core::PaginationTestHelpers
end
```

---

## How It Works

Each module is a plain Ruby concern (`ActiveSupport::Concern`). When included:

 1. **`Core::ResourceTest`** is the entry point — includes all other helpers and provides the `resource_test` class macro that generates all tests at class-definition time. In most cases this is the only module you include.

 2. **`Core::AuthTestHelpers`** hooks a `setup` callback that generates JWT tokens for the `super_admin` and `attendee` fixture users once per test. These are memoized in instance variables.

 3. **`Core::AuthorizationTestHelpers`** builds on `AuthTestHelpers` with `assert_permitted`, `assert_forbidden`, and `assert_unauthorized`. Pass a fixture key and action symbol — it generates the JWT, fires the HTTP verb, and asserts the expected status.

 4. **`Core::CrudTestHelpers`** provides assertion methods that wrap HTTP requests (`get`, `post`, `patch`, `delete`) with JSON headers, response parsing, and common checks (`success`, `created`, `forbidden`). They return the parsed `data` payload so you can chain additional assertions.

 5. **`Core::PaginationTestHelpers`** builds query strings for `page`, `per_page`, `order_by`, `order_direction`, and `q[field_cont]` parameters, then verifies the response structure.

 6. **`Core::AuditTestHelpers`** queries `Core::AuditLog` with scopes for action, auditable, and actor.

The key design decisions:

- **Default to admin auth** — CRUD helpers default to `headers: admin_headers`. To test unauthorized access, pass `headers: user_headers` explicitly.
- **Fluent chaining** — `assert_create` and friends return `payload["data"]` so you can assert on the returned record.
- **Configurable attribute checks** — `check_attributes` lets you verify specific fields inline.

---

## Core::ResourceTest

A class macro that auto-generates **all** CRUD tests — authorization, audit, show attributes, index pagination/ordering, and destroy verification — by introspecting the controller, model, policy, and fixtures at class-load time.

### Zero-config usage

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test  # <-- generates ~36 tests, zero options needed
end
```

That's it. No manual tests to write. The macro auto-detects everything and generates comprehensive coverage.

### What it generates

For a 5-action REST controller with 3 fixture keys (`super_admin`, `core_admin`, `attendee`) and `auditable on: %i[create update destroy]`:

| Category | Tests generated | Count |
|----------|----------------|-------|
| **Unauthorized** | `#{action} fails for unauthenticated user` — asserts `401` | 5 |
| **Role-based** | `#{action} permitted/forbidden for #{fixture_key}` — asserts `2xx` or `403` per policy | 15 |
| **Audit success** | `#{action} logs an audit` — asserts audit record created with correct action/actor | 3 |
| **Audit forbidden** | `forbidden #{action} does not enqueue an audit` — asserts no audit record for unauthorized | 3 |
| **Show attributes** | `show returns expected attributes` — asserts response data has all model columns | 1 |
| **Index pagination** | `index pagination works` — asserts pagination metadata with `per_page: 2` | 1 |
| **Index ordering** | `index ordering works` — asserts default ordering by `created_at desc` | 1 |
| **Attribute presence** | `#{action} returns expected attributes` — asserts declared serializer fields are present | ~5 |
| **Attribute absence** | `#{action} excludes hidden attributes` — asserts hidden attributes are absent | ~3 |
| **Destroy verification** | `destroy removes the record` — creates disposable record, deletes, asserts gone | 1 |
| **Total** | | **~36** |

### How auto-detection works

The `Metadata` class resolves everything at class-definition time:

| What | Source | Override |
|------|--------|----------|
| **Controller** | Test class name (`EventsCategoriesTest` → `Events::CategoriesController`) | `path:` |
| **Path** | Controller name (`/events/categories`) | `path:` |
| **Model** | `self.model_class` from `Core::Common` | `model:` |
| **Param key** | `controller_name.singularize` (`"category"`) | — |
| **Fixture keys** | `core_users.yml` fixture names | — |
| **Auditable actions** | `_audit_configs` from `auditable on:` | — |
| **Actions to test** | `action_methods` ∩ `%i[index show create update destroy]` - `except:` | `except:` |
| **Policy results** | Reads 5 fixture YAML files → builds `MockUser` per fixture → evaluates policy | — |
| **Create params** | First fixture entry in model's fixture file (excludes id, slug, timestamps, ERB values) | `create_params:` |
| **Show attributes** | `serializer_profile[:show][:fields]` from controller | `check_attributes: { show: }` |
| **Index attributes** | `serializer_profile[:index][:fields]` from controller | `check_attributes: { index: }` |
| **Absent attributes** | Computed as full serializer attribute set minus `serializer_profile[action][:fields]` — auto-generates absence tests | `check_attributes: { show_absent: }` |
| **Pagination** | Default `per_page: 2` | `index: { pagination: }` |
| **Ordering** | Default `created_at desc` | `index: { ordering: }` |

### Auto-detected fixture params

The macro reads the model's fixture file (e.g., `test/fixtures/events_categories.yml`) and extracts the first entry's attributes, excluding auto-generated fields (`id`, `slug`, `created_at`, `updated_at`) and ERB expressions.

For `events_categories.yml`:
```yaml
music:
  name: Music
  description: Concerts, festivals, and live performances
  metadata:
    icon: "music-note"
    color: "#FF5733"
  active: true
```

The macro generates create params like:
```ruby
{ "category" => { name: "Music a1b2c3d4", description: "Concerts, festivals...", metadata: { icon: "music-note" }, active: true } }
```

The name gets a random hex suffix to avoid uniqueness violations.

### Options API

```ruby
resource_test(
  except: [],                    # Actions to exclude
  path: nil,                     # Override resource path
  model: nil,                    # Override model class
  record: nil,                   # Proc for record lookup (show/update/destroy)
  create_params: nil,            # Proc for create params (-> { { key => attrs } })
  update_params: nil,            # Proc for update params (->(record) { { key => attrs } })
  skip_authorization: false,     # Skip unauthorized 401 tests (matches controller DSL; alias: skip_unauthorized)
  check_attributes: {            # Response attribute verification
    show: %w[name description],  #   Verify these keys exist in show response
    create: { slug: "comedy" },  #   Verify key/value pairs in create response
    update: { name: "Updated" }  #   Verify key/value pairs in update response
  },
  index: {                       # Index action extras
    pagination: { per_page: 5 }, #   Generate pagination test
    ordering: { order_by: "name", direction: "asc" },  # Generate ordering test
    filtering: { param: "q[name_cont]=music", check: ->(item) { ... } }
  }
)
```

All options are optional. Zero-config means zero options.

### When options are needed

**Custom create/update params** — when the auto-detected fixture params don't work (e.g., required associations, complex nested attributes):

```ruby
resource_test(
  create_params: -> { { event: { name: "Festival", category_id: events_categories(:music).id } } },
  update_params: ->(r) { { event: { name: "Updated #{r.name}" } } }
)
```

**Business logic verification** — assert specific values in create/update responses:

```ruby
resource_test(
  create_params: -> { { category: { name: "Comedy", metadata: { icon: "laugh" } } } },
  check_attributes: {
    create: { name: "Comedy", slug: "comedy" },
    update: { name: "Updated Music" }
  }
)
```

**Custom record for show/update/destroy** — when `model_class.first` is not the right record:

```ruby
resource_test(
  record: -> { events_categories(:music) }
)
```

**Custom pagination/ordering/filtering** — override defaults or add filtering:

```ruby
resource_test(
  index: {
    pagination: { per_page: 5 },
    ordering: { order_by: "name", direction: "asc" },
    filtering: { param: "q[name_cont]=music", check: ->(item) { item["name"].downcase.include?("music") } }
  }
)
```

**Excluding actions** — skip actions that shouldn't have auth tests:

```ruby
resource_test except: %i[index show]
```

**Attribute visibility override** — when the auto-detected `serializer_profile` produces wrong expectations (e.g., you have `serializer_profile` but want to skip absence checks for a specific action):

```ruby
resource_test(
  check_attributes: {
    show: %w[id name description slug metadata active created_at updated_at],
    show_absent: []  # don't check absence for show (everything is visible)
  }
)
```

Or if you're **not** using `serializer_profile` but want manual attribute tests:

```ruby
resource_test(
  check_attributes: {
    index: %w[id name slug],
    index_absent: %w[description metadata active created_at updated_at],
    show: %w[id name description slug metadata active]
  }
)
```

### What auto-generated attribute tests look like

When the controller defines `serializer_profile`:

```ruby
def serializer_profile
  {
    index:  { fields: %i[id name slug] },
    show:   { fields: %i[id name description slug metadata active created_at updated_at] },
    create: { fields: %i[id name slug] },
    update: { fields: %i[id name slug] }
  }
end
```

The macro generates tests like:

```
test "index returns expected attributes" do
  get "/events/categories", headers: admin_headers, as: :json
  assert_response :success
  JSON.parse(response.body)["data"].each { |item| assert item.key?("id"); assert item.key?("name"); assert item.key?("slug") }
end

test "index excludes hidden attributes" do
  get "/events/categories", headers: admin_headers, as: :json
  assert_response :success
  data = JSON.parse(response.body)["data"].first
  assert_not data.key?("description"); assert_not data.key?("metadata")
  assert_not data.key?("active"); assert_not data.key?("created_at"); assert_not data.key?("updated_at")
end

test "show returns expected attributes" do
  get "/events/categories/<id>", headers: admin_headers, as: :json
  assert_response :success
  data = JSON.parse(response.body)["data"]
  assert data.key?("id"); assert data.key?("name"); # ... all show fields
end
```

For role-specific visibility (like attendee vs admin show), you still write explicit tests since the auto-generated tests use `admin_headers`:

### Fixture requirements (for RBAC)

All 5 fixture files must exist at class-load time for RBAC policy evaluation:

- `test/fixtures/core_users.yml`
- `test/fixtures/core_roles.yml`
- `test/fixtures/core_user_roles.yml`
- `test/fixtures/core_role_permissions.yml`
- `test/fixtures/core_permissions.yml`

The model's own fixture file (e.g., `events_categories.yml`) is needed only if you want auto-detected create params.

### MockUser

The `Metadata::MockUser` struct evaluates policy rules at class-load time without a database:

```ruby
MockUser.new(role_codes: ["SUPER_ADMIN"], perm_codes: ["category.create"])
user.super_admin?                        # => true
user.has_role?("SUPER_ADMIN")            # => true
user.has_permission?("category.create")  # => true (super_admin or perm match)
```

### Important notes

- **`include Core::ResourceTest` must come first** — `resource_test` is a class method that runs at class-definition time.
- **Auto-includes** `Core::AuthTestHelpers`, `Core::AuditTestHelpers`, `Core::CrudTestHelpers`, `Core::PaginationTestHelpers`, and `ActiveJob::TestHelper`. No separate includes needed.
- **Fixture YAML is read at class-load time**, not test runtime. If fixture files change, the test file must be reloaded.
- **Nil record for unauthorized tests** uses `"nonexistent"` as a dummy ID — the auth check runs before the record lookup.
- **Destroy test** creates a disposable record (using auto-detected or user-provided `create_params`), deletes it via the first permitted user, and asserts it's gone. This never touches fixture data.

### Per-action attribute visibility

Controllers declare a `serializer_profile` that defines which attributes (`fields:`) and associations (`include:`) to expose per action. An optional `default` key provides shared config:

```ruby
# app/controllers/events/categories_controller.rb
private

def serializer_profile
  {
    index: {
      fields: %i[id name slug]
    },
    show: {
      fields: %i[id name description slug metadata active created_at updated_at]
    },
    create: {
      fields: %i[id name slug]
    },
    update: {
      fields: %i[id name slug]
    }
  }
end
```

When present, `resource_test` auto-detects the expected attributes per action and generates:
- **Presence tests**: verifies declared attributes are in the response
- **Absence tests**: verifies hidden attributes are absent (computed from the serializer's full attribute set)

If `serializer_profile` returns `{}` (default), `resource_test` falls back to `column_names` for show/index check_attributes.

### Per-role attribute visibility

Policies can further restrict visible attributes per role using a `VISIBILITY` hash:

```ruby
# app/policies/events/category_policy.rb
VISIBILITY = {
  show: {
    default: %i[id name description slug metadata active],  # restrict for non-admin
    admin: nil                                                # admin sees everything
  }
}.freeze

def visible_attributes_for(record:, action:)
  config = VISIBILITY[action.to_sym]
  return nil unless config

  if config.key?(user_role_key)
    config[user_role_key]
  else
    config[:default]
  end
end

private

def user_role_key
  return :admin if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
  :default
end
```

Only declare actions in `VISIBILITY` when roles diverge. Unlisted actions are unrestricted — controller `serializer_profile` decides alone.

If `visible_attributes_for` returns `nil`, all serializer attributes pass through. If it returns a list, that list is intersected with the controller's `serializer_profile[action][:fields]` (if any). Resolution order:

1. Controller `serializer_profile[action][:fields]` — declares the endpoint's field profile (with `default` inheritance)
2. Policy `visible_attributes_for(record:, action:)` — restricts per role
3. Final set = intersection of both (or full set if either is nil)

### AttributeVisibilitySerializer

The `Core::AttributeVisibilitySerializer` concern is included in serializers that support attribute filtering. It slices the serialized output based on `visible_attributes` passed through AMS `instance_options`:

```ruby
module Events
  class CategorySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
    has_many :audit_logs, serializer: Core::AuditLogSerializer
  end
end
```

All serializers in modules that use `serializer_profile` with `fields:` must include this concern. Without it, the `visible_attributes` option is ignored and the full payload is returned.

Associations (`has_many`, `has_one`) are **not** affected by the fieldset — they remain controlled by `serializer_profile[action][:include]`.

### How the pipeline works

```
Controller action (e.g., #show)
  ↓
Core::Common serializes the record
  ↓
Core::JsonResponse#render_success
  ↓  calls resolved_visible_attributes(data)
  ↓    1. Reads controller_fields = serializer_profile.dig(action_name, :fields) || serializer_profile.dig(:default, :fields)
  ↓    2. Reads policy_fields = policy_visible_attributes_for(data)
  ↓    3. Returns intersection (or nil if both absent)
  ↓
Passes visible_attributes into AMS via instance_options
  ↓
AttributeVisibilitySerializer#attributes slices output
  ↓
JSON response
```

### Files involved

| File | Responsibility |
|------|---------------|
| `app/controllers/concerns/core/json_response.rb` | Provides `serializer_profile` default (`{}`), `resolved_visible_attributes`, `policy_visible_attributes_for`. `render_success` passes `visible_attributes` into serialization options. |
| `app/controllers/events/categories_controller.rb` | Overrides `serializer_profile` to define per-action attribute profiles. |
| `app/policies/core/application_policy.rb` | Provides `visible_attributes_for(record:, action:)` default (nil). |
| `app/policies/events/category_policy.rb` | Defines `VISIBILITY` hash for per-role restrictions. |
| `app/serializers/core/attribute_visibility_serializer.rb` | AMS concern that slices serialized output by `visible_attributes`. |
| `app/serializers/events/category_serializer.rb` | Includes the concern. |

### Adding to a new domain module

1. Add `serializer_profile` as a private method in the controller:
   ```ruby
   def serializer_profile
     {
       index:  { fields: %i[id name slug] },
       show:   { fields: %i[id name ...] },
       create: { fields: %i[id name slug] },
       update: { fields: %i[id name slug] }
     }
   end
   ```
2. Add `VISIBILITY` hash in the policy (optional, for per-role restrictions):
   ```ruby
   VISIBILITY = {
     show: {
       default: %i[id name description slug metadata active],
       admin: nil
     }
   }.freeze

   def visible_attributes_for(record:, action:)
     config = VISIBILITY[action.to_sym]
     return nil unless config
     config.key?(user_role_key) ? config[user_role_key] : config[:default]
   end
   ```
   Only add actions to `VISIBILITY` when roles diverge. Unlisted actions are unrestricted — the controller's `serializer_profile` decides alone.
3. Include `Core::AttributeVisibilitySerializer` in the serializer.
4. `resource_test` auto-detects everything — no test changes needed.
5. Add explicit tests only for role-specific visibility that auto-detection can't reach (like attendee vs admin).

---


## Core::AuthTestHelpers

### What it provides

| Method | Return | Description |
|--------|--------|-------------|
| `admin_headers` | `Hash` | `{ "Authorization" => "Bearer <super_admin_jwt>" }` |
| `user_headers` | `Hash` | `{ "Authorization" => "Bearer <attendee_jwt>" }` |

### How it works

On `setup`, it calls `Core::TokenService.issue` for the `super_admin` and `attendee` fixture users and stores the tokens in `@auth_admin_token` / `@auth_user_token`. The header accessors wrap them in the `Authorization` header format.

### Usage

```ruby
class MyTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  test "admin can access" do
    get "/resource", headers: admin_headers, as: :json
    assert_response :success
  end

  test "regular user cannot access" do
    get "/resource", headers: user_headers, as: :json
    assert_response :forbidden
  end
end
```

### Custom token

If you need a token for a different fixture user:

```ruby
token = issue_token(:organizer_user)
headers = { "Authorization" => "Bearer #{token}" }
```

---

## Core::AuthorizationTestHelpers

Includes `Core::AuthTestHelpers` automatically. No need to include both.

### What it provides

| Method | Return | Description |
|--------|--------|-------------|
| `assert_permitted(fixture_key, action, path, ...)` | `Hash` (parsed data) | Asserts the request succeeds (2xx) with the given role |
| `assert_forbidden(fixture_key, action, path, ...)` | `nil` | Asserts `403` with the given role |
| `assert_unauthorized(action, path, ...)` | `nil` | Asserts `401` with no auth header |

### Parameters

| Param | Required | Description |
|-------|----------|-------------|
| `fixture_key` | yes | Fixture key for `core_users` (e.g. `:super_admin`, `:attendee`) |
| `action` | yes | One of `:index`, `:show`, `:create`, `:update`, `:destroy` |
| `path` | yes | Resource path (e.g. `"/events/categories"`) |
| `record:` | for `:show`/`:update`/`:destroy` | ActiveRecord instance |
| `params:` | for `:create`/`:update` | Request body hash |

### Usage

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::AuthorizationTestHelpers  # also pulls in AuthTestHelpers

  RESOURCE_PATH = "/events/categories"

  test "admin can create" do
    assert_permitted :super_admin, :create, RESOURCE_PATH,
      params: { category: { name: "Comedy" } }
  end

  test "attendee cannot create" do
    assert_forbidden :attendee, :create, RESOURCE_PATH,
      params: { category: { name: "Hacked" } }
  end

  test "unauthenticated request is rejected" do
    assert_unauthorized :create, RESOURCE_PATH,
      params: { category: { name: "Nope" } }
  end
end
```

### How it works

Calling `assert_permitted(:super_admin, :create, path, params: {...})`:

1. Generates a fresh JWT for `core_users(:super_admin)`
2. Sends `POST #{path}` with the params and token in the `Authorization` header
3. Asserts the response status is in the 2xx range
4. Returns the parsed `data` payload

`assert_forbidden` and `assert_unauthorized` work the same way but assert `403` and `401` respectively, and return `nil`.

### When to use over CrudTestHelpers

- **Use `AuthorizationTestHelpers`** when you need to test authorization rules explicitly — different roles, expected status codes, role-specific access.
- **Use `CrudTestHelpers`** when you need full CRUD assertions (response structure, attribute verification, resource lifecycle checks). The CRUD helpers default to `admin_headers` and offer `check_attributes`.

---

## Core::CrudTestHelpers

### assert_index

```ruby
records = assert_index(resource_path, headers: admin_headers)
```

Performs `GET <resource_path>` and asserts:
- Response status is `200`
- `response.body["success"]` is `true`
- `response.body["data"]` is present

Returns the `data` array for further assertions.

```ruby
categories = assert_index("/events/categories")
assert categories.any? { |c| c["name"] == "Music" }
```

---

### assert_show

```ruby
record = assert_show(resource_path, record, headers: admin_headers, check_attributes: %w[id name slug])
```

Performs `GET <resource_path>/<record.id>` and asserts:
- Response status is `200`
- `success` is `true`
- Each attribute in `check_attributes` is present in `data`

Returns the `data` hash.

```ruby
category = events_categories(:music)
data = assert_show("/events/categories", category, check_attributes: %w[id name slug])
assert_equal "Music", data["name"]
```

---

### assert_create

```ruby
record = assert_create(resource_path, params, headers: admin_headers, check_attributes: {})
```

Performs `POST <resource_path>` with `params` and asserts:
- Response status is `201`
- `success` is `true`
- Each key/value in `check_attributes` matches `data[key]`

Returns the created `data` hash.

```ruby
data = assert_create("/events/categories",
  { category: { name: "Comedy", metadata: {} } },
  check_attributes: { "name" => "Comedy", "slug" => "comedy" })
```

---

### assert_create_forbidden (deprecated)

> Prefer `assert_forbidden :attendee, :create, path, params:` from `AuthorizationTestHelpers`.

```ruby
assert_create_forbidden(resource_path, params, headers: user_headers)
```

Performs `POST <resource_path>` and asserts response status is `403`.

```ruby
assert_create_forbidden("/events/categories",
  { category: { name: "Comedy" } })
```

---

### assert_update

```ruby
record = assert_update(resource_path, record, params, headers: admin_headers, check_attributes: {})
```

Performs `PATCH <resource_path>/<record.id>` with `params` and asserts:
- Response status is `200`
- `success` is `true`
- Each key/value in `check_attributes` matches `data[key]`

Returns the updated `data` hash.

```ruby
category = events_categories(:music)
assert_update("/events/categories", category,
  { category: { name: "Live Music" } },
  check_attributes: { "name" => "Live Music" })
```

---

### assert_update_forbidden (deprecated)

> Prefer `assert_forbidden :attendee, :update, path, record:, params:` from `AuthorizationTestHelpers`.

```ruby
assert_update_forbidden(resource_path, record, params, headers: user_headers)
```

Performs `PATCH <resource_path>/<record.id>` and asserts response status is `403`.

```ruby
category = events_categories(:music)
assert_update_forbidden("/events/categories", category,
  { category: { name: "Hacked" } })
```

---

### assert_destroy

```ruby
assert_destroy(resource_path, record, headers: admin_headers)
```

Performs `DELETE <resource_path>/<record.id>` and asserts:
- Response status is `200`
- `success` is `true`

```ruby
category = Events::Category.create!(name: "Temp", metadata: {})
assert_destroy("/events/categories", category)
assert_resource_deleted(Events::Category, category)
```

---

### assert_destroy_forbidden (deprecated)

> Prefer `assert_forbidden :attendee, :destroy, path, record:` from `AuthorizationTestHelpers`.

```ruby
assert_destroy_forbidden(resource_path, record, headers: user_headers)
```

Performs `DELETE <resource_path>/<record.id>` and asserts response status is `403`.

```ruby
category = events_categories(:music)
assert_destroy_forbidden("/events/categories", category)
assert_resource_not_deleted(Events::Category, category)
```

---

### assert_resource_deleted / assert_resource_not_deleted

```ruby
assert_resource_deleted(ModelClass, record)
assert_resource_not_deleted(ModelClass, record)
```

Convenience wrappers:
- `assert_resource_deleted` — asserts `ModelClass.find_by(id: record.id)` is `nil`
- `assert_resource_not_deleted` — asserts `ModelClass.exists?(record.id)` is `true`

---

## Core::PaginationTestHelpers

### assert_pagination_works

```ruby
payload = assert_pagination_works(resource_path, headers: admin_headers, per_page: 2)
```

Performs `GET <resource_path>?page=1&per_page=<per_page>` and asserts:
- Response status is `200`
- `pagination` metadata is present
- `pagination["per_page"]` matches the requested count
- `pagination["current_page"]` is `1`
- `pagination["total_count"]`, `total_pages`, and `links` are present

Returns the full response payload.

```ruby
assert_pagination_works("/events/categories", per_page: 2)
```

---

### assert_filtering_works

```ruby
records = assert_filtering_works(resource_path,
  filter_params: "q[name_cont]=music",
  headers: admin_headers,
  check: ->(item, _params) { item["name"].downcase.include?("music") })
```

Performs `GET <resource_path>?<filter_params>` and asserts:
- Response status is `200`
- `data` is present
- Every item in `data` passes the `check` lambda

The `check` lambda receives `(item, filter_params)` so you can inspect the raw query string if needed.

```ruby
assert_filtering_works("/events/categories",
  filter_params: "q[name_cont]=music",
  check: ->(item, _) { item["name"].downcase.include?("music") })
```

---

### assert_ordering_works

```ruby
records = assert_ordering_works(resource_path,
  order_by: :name,
  direction: "desc",
  headers: admin_headers)
```

Performs `GET <resource_path>?order_by=<field>&order_direction=<direction>` and asserts:
- Response status is `200`
- The items are sorted correctly by the specified field in the specified direction

The comparison uses `sort_by { |v| v.to_s.downcase }` for case-insensitive matching.

```ruby
assert_ordering_works("/events/categories", order_by: :name, direction: "desc")
```

---

## Core::AuditTestHelpers

### assert_audit_logged

```ruby
assert_audit_logged(action: "create", auditable: record, actor: user)
```

Asserts at least one `Core::AuditLog` exists matching the given action, auditable, and actor. Each parameter is optional — omit `auditable` to check the action globally, or omit `actor` to check regardless of who performed it.

```ruby
category = events_categories(:music)
patch "/events/categories/#{category.id}",
  params: { category: { name: "Updated" } },
  headers: admin_headers, as: :json
assert_audit_logged(action: "update", auditable: category)
```

---

### assert_audit_not_logged

```ruby
assert_audit_not_logged(action: "destroy", auditable: record)
```

Asserts no `Core::AuditLog` exists for the given action/auditable combination.

---

### assert_audit_log_count

```ruby
assert_audit_log_count(action: "create", auditable: record, expected: 1)
```

Asserts the exact count of matching audit log entries.

---

## Core::SlugableTest

A model-level test helper for models that include `Core::Slugable`. Generates slug tests from a single `test_slugable` call:

1. **Generates slug from the source column** — creates a record and asserts the slug matches the parameterized source value
2. **Updates slug when the source changes** — creates a record, updates the source column, and asserts the slug is regenerated
3. **Handles duplicate slugs with counter** (only with `create_params:`) — creates two records with the same source value and asserts the second gets a `-1` suffix

The duplicate slug test is only generated when `create_params:` is provided. In zero-config mode, the duplicate test is skipped because many models have uniqueness validation on the source column (e.g., `validates :name, uniqueness: true`), which would cause a conflict.

### Zero-config usage (simplest)

When the model has no belongs_to or required associations:

```ruby
class Events::VenueTest < ActiveSupport::TestCase
  include Core::SlugableTest

  test_slugable  # generates 2 tests automatically
end
```

The helper creates a record with `{ <source_column> => "Test" }`.

### With create_params

When the model requires additional attributes (e.g. a belongs_to FK), pass `create_params:`:

```ruby
class Events::VenueTest < ActiveSupport::TestCase
  include Core::SlugableTest

  setup do
    @category = Events::Category.create!(name: "Setup Category")
  end

  test_slugable create_params: -> { { name: "My Venue", category_id: @category.id } }
end
```

With `create_params:` provided, all 3 tests are generated (including the duplicate slug counter test).

### How it works

The helper reads `_slug_source` and `_slug_target` class attributes from the model (set by the `slugable` macro) to know which column drives slug generation and which column stores the result. It infers the model class from the test class name (removing the `Test` suffix) — supports both `Events::VenueTest` and `EventsCategoryTest` naming conventions.

---

## Complete Example

Here's the current `Events::Categories` integration test. `resource_test` generates ~35 tests, plus one explicit test for attendee-specific attribute visibility that auto-detection can't cover:

```ruby
require "test_helper"

class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  test "show hides timestamps for attendee" do
    record = Events::Category.first
    get "/events/categories/#{record.id}", headers: user_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_not data.key?("created_at")
    assert_not data.key?("updated_at")
  end

  resource_test
end
```

That generates these tests:

| Unauthorized | Role-based | Audit | Extras | Attribute visibility |
|---|---|---|---|---|
| `index fails for unauthenticated user` | `index permitted/forbidden for super_admin` | `create logs an audit` | `show returns expected attributes` | `show hides timestamps for attendee` |
| `show fails for unauthenticated user` | `index permitted/forbidden for core_admin` | `update logs an audit` | `index pagination works` | Also auto-generated: `index excludes hidden attributes` |
| `create fails for unauthenticated user` | `index permitted/forbidden for attendee` | `destroy logs an audit` | `index ordering works` | Also auto-generated: `create excludes hidden attributes` |
| `update fails for unauthenticated user` | `show ... for super_admin/core_admin/attendee` | `forbidden create does not enqueue an audit` | `destroy removes the record` | Also auto-generated: `update excludes hidden attributes` |
| `destroy fails for unauthenticated user` | `create ... for super_admin/core_admin/attendee` | `forbidden update does not enqueue an audit` | `index returns expected attributes` | |
| | `update ... for super_admin/core_admin/attendee` | `forbidden destroy does not enqueue an audit` | | |
| | `destroy ... for super_admin/core_admin/attendee` | | | |

If you want custom business logic verification, add options:

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test(
    create_params: -> { { category: { name: "Comedy", metadata: { icon: "laugh" } } } },
    check_attributes: {
      create: { name: "Comedy", slug: "comedy" },
      update: { name: "Updated" }
    },
    index: {
      filtering: { param: "q[name_cont]=music", check: ->(item) { item["name"].downcase.include?("music") } }
    }
  )
end
```

Or for a fully manual controller that doesn't fit the CRUD pattern:

```ruby
class CustomReportsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers
  include Core::AuthorizationTestHelpers

  # Write all tests manually with assert_permitted/assert_forbidden
end
```

---

## Migrating an Existing Test

**Before** (manual auth and CRUD in every test):

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  def admin_token
    user = core_users(:super_admin)
    Core::TokenService.issue(Core::TokenService.access_token_payload(user))
  end

  test "index" do
    get "/events/categories", headers: { "Authorization" => "Bearer #{admin_token}" }, as: :json
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload["success"]
    assert payload["data"].present?
  end
  # ... more tests, each repeating the same auth pattern
end
```

**After**:

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers
  include Core::CrudTestHelpers

  test "index" do
    assert_index("/events/categories")
  end
  # ... cleaner tests throughout
end
```

---

## Adding a New Module

If you need to create a new support module:

1. Create the file in `test/support/core/<name>_test_helpers.rb`
2. Use `extend ActiveSupport::Concern` and wrap methods in `private`
3. It will be auto-loaded — no changes to `test_helper.rb` needed

```ruby
# test/support/core/soft_delete_test_helpers.rb
module Core
  module SoftDeleteTestHelpers
    private

    def assert_soft_deleted(model_class, record)
      assert record.reload.deleted_at.present?
    end

    def assert_not_soft_deleted(model_class, record)
      assert record.reload.deleted_at.nil?
    end
  end
end
```

Then include in any test:

```ruby
class MyTest < ActionDispatch::IntegrationTest
  include Core::SoftDeleteTestHelpers
end
```
