# Domain Module Generator

A Rails generator that scaffolds a complete domain module — model, migration, controller, serializer, policy, locale, tests, fixtures, and route — following the platform's modular monolith conventions.

## Quick Start

```bash
# Simple model with a name
rails generate domain_module Events::Category name:string

# With columns, audit logging, and slugs
rails generate domain_module Events::Event name:string description:text \
  'event:belongs_to[Events::Event]' --auditable --slug-source=name

# Cross-namespace belongs_to
rails generate domain_module Ticketing::Ticket \
  'event:belongs_to[Events::Event]' price_cents:integer --no-auditable

# Nested resource under a parent
rails generate domain_module Organizations::Membership role:integer \
  user:belongs_to[Core::User] --parent=Organizations::Organization --no-interactive

# Non-interactive mode (no prompts)
rails generate domain_module Events::Event name:string --no-interactive

## Destroy

Removes all generated files: migration, model, controller, serializer,
policy, fixtures, and tests. The route and `set_fixture_class` mapping
are also reversed.

```bash
rails destroy domain_module Events::Event
```

**Known limitation:** The migration filename is reconstructed from the
current timestamp on destroy and may not match the actual file created
during generation. The old migration file may need manual cleanup if
the destroy leaves it behind.

```

## Generated Files

For `Events::Event`, the generator creates:

| File | Contents |
|------|----------|
| `db/migrate/TIMESTAMP_create_events_events.rb` | UUID primary key, all columns, timestamps, optional slug + unique index |
| `app/models/events/event.rb` | Namespaced model with `table_name`, belonging, validations, scopes, ransackable config |
| `app/controllers/events/events_controller.rb` | CRUD controller with `Core::Common`, `serializer_profile`, `model_params`, authorization |
| `app/serializers/events/event_serializer.rb` | AMS serializer with `AttributeVisibilitySerializer`, belongs_to declarations |
| `app/policies/events/event_policy.rb` | Pundit policy with default role checks, `VISIBILITY` hash, Scope class |
| `test/fixtures/events_events.yml` | Two fixture records with sample data, UUIDs, optional slugs |
| `test/integration/events/events_test.rb` | Integration tests using `resource_test` DSL — authorization, audit, CRUD, pagination, attribute visibility |
| `config/routes.rb` | Namespaced RESTful route (except new/edit) |
| `test/test_helper.rb` | `set_fixture_class` mapping inserted |
| `config/locales/events/event.en.yml` | I18n locale file with success/error messages per action |

If the namespace is new, also creates:

| File | Contents |
|------|----------|
| `app/models/NAMESPACE/application_record.rb` | Abstract base record inheriting `Core::ApplicationRecord` |
| `app/controllers/NAMESPACE/application_controller.rb` | Base controller inheriting `Core::ApplicationController` |

## Column Syntax

```

name:string
description:text
price_cents:integer
quantity:integer
rating:decimal
weight:float
active:boolean
event_date:date
started_at:datetime
metadata:jsonb
event:belongs_to                        # same namespace: Events::Event
event:belongs_to[Events::Event]         # explicit class (cross-namespace)
event:belongs_to[Core::User]            # cross-namespace reference

```

The bracket notation `[ClassName]` specifies the target class for belongs_to. Without brackets, the class is inferred as `Namespace::Name` (same namespace).

### `name` column special behavior

When a `name:string` column is present:
- Model gets `validates :name, presence: true`
- Integration test uses bare `resource_test` (no explicit params) when there are no belongs_to columns
- Slug source defaults to `name` when `--slug-source` is omitted

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--auditable` / `--no-auditable` | `true` | Include `Core::AuditableModel` + `Core::AuditableController`. Adds audit logging callbacks, `Core::AuditLoggerJob` enqueue on create/update/destroy |
| `--slug` / `--no-slug` | `false` | Enable `Core::Slugable`. Adds slug column, unique index, `before_validation` slug generation, `validates :slug` |
| `--slug-source=COL` | `name` | Source column for slug generation (implies `--slug`). Falls back to `name` if omitted |
| `--skip-migration` | `false` | Don't create the migration file |
| `--skip-routes` | `false` | Don't add route to `config/routes.rb` |
| `--skip-tests` | `false` | Don't create test/fixture files |
| `--interactive` / `--no-interactive` | `true` | Prompt for auditable, slug, slug_source when not explicitly provided. Use `--no-interactive` for scripting |
| `--only=COMPONENTS` | (none) | Only generate the listed components (comma-separated). Valid values: `migration`, `model`, `controller`, `serializer`, `policy`, `locale`, `fixture`, `integration_test`, `route`. Errors on invalid entries. |
| `--parent=MODEL` | (none) | Scopes the generated controller under a parent model. Sets `parent_class`, `parent_param`, and `parent_association` on the controller. Generates nested routes and an integration test with a callable `path:` lambda. The child must have a `belongs_to` column referencing the parent model. The parent model must already exist — run its domain_module generator first. |
| `--skip=COMPONENTS` | (none) | Skip the listed components. Same valid values as `--only`. Cannot be combined with `--only`. |

### Component Selection

Use `--only` to generate a subset of components, or `--skip` to exclude specific ones. These are mutually exclusive — only one of `--only` or `--skip` may be used per invocation.

```bash
# Generate only controller and serializer
rails generate domain_module Events::Venue name:string --only controller serializer --no-interactive

# Generate everything except migration and model
rails generate domain_module Events::Venue name:string --skip migration model --no-interactive
```

Invalid component names raise a `Thor::Error` with a descriptive message:

## Generated Code Conventions

### Policy authorization defaults
- `index?` / `show?`: always permitted (`true`)
- `create?` / `update?`: requires `SUPER_ADMIN` or `ADMIN` role
- `destroy?`: requires `SUPER_ADMIN` role
- Override these in the generated policy for domain-specific rules.

### `VISIBILITY` — required on all policies
Every policy must define a `VISIBILITY` hash, even if no role-based field restriction is needed. This makes attribute visibility explicit and documents the policy's access model:

```ruby
VISIBILITY = {
  show: {
    default: nil,   # unrestricted — owner sees all fields
    admin: nil      # unrestricted — super_admin sees all fields
  }
}.freeze
```

- **`nil`** = unrestricted (all serializer fields pass through)
- **`{ fields: %i[id name] }`** = restricts to those fields for that role
- **`{ include: [:association] }`** = adds associations for that role
- Use `default:` as the fallback for non-admin roles. Add role-specific keys to override.
- Only declare actions where roles differ — unlisted actions are unrestricted.

### Serializer profile
The generated controller uses empty per-action hashes:
```ruby
def serializer_profile
  { index: {}, show: {}, create: {}, update: {} }
end
```

This means no controller-level field whitelisting — attribute visibility is governed entirely by the policy's `VISIBILITY` hash. Add per-action `{ fields: %i[id name] }` entries to restrict.

### Fixture belongs_to keys

FK values are intentionally omitted from the fixture YAML. They're supplied at test time via the `setup` block in the integration test, which creates real persisted records using `Model.create!`.

### Integration test pattern

Models with `belongs_to` columns or without a `name` column generate explicit `create_params`/`update_params` lambdas. Models with `name` and no `belongs_to` columns use the bare `resource_test` (zero-config) form.

### Audit logging tests

Auditable models generate 2 additional tests per CRUD action: one verifying the audit is logged (permitted user), one verifying it's not logged (forbidden user). Tests use `perform_enqueued_jobs` to run `Core::AuditLoggerJob` inline.

### `belongs_to` setup uses `create!`

The `setup` block in generated tests uses `Model.create!(name: "Setup ...")`. Validations and callbacks run normally. Edit the setup block if the target model requires additional attributes.

### Post-generation checklist for `belongs_to`

After generating a model with `belongs_to` columns, check these files for manual adjustments:

| File | What to check | Why |
|------|---------------|-----|
| `test/integration/..._test.rb` | The `setup` block creates parent records with `create!(name: "Setup ...")`. If the parent doesn't have a `name` column, change it to a valid column (e.g. `title`, `code`). If `name` has uniqueness validation and "Setup ..." clashes with fixture data, use a unique value (e.g. `"Setup Parent #{SecureRandom.hex(4)}"`). | The generator hardcodes `name:` in the `create!` call — it doesn't introspect the parent model's columns. |
| `test/integration/..._test.rb` | `create_params` and `update_params` lambdas reference `@parent.id`. These are correct if the `setup` block is correct. No manual fix needed unless the setup changes. | The FKs flow naturally from the setup. |
| `test/fixtures/*.yml` | FK values are intentionally omitted. Fixture records don't have `belongs_to` associations — they're only used for read-only tests (index/show/destroy). | If you need fixture records with associations for a specific test, add FK values manually to the YAML. |

**Summary of assumptions the generator makes about parent models:**

1. Parent has a column that can be set to a unique string value (defaults to `name`)
2. Parent can be created with just that one column value
3. Parent doesn't have validations that would reject the generated value
4. Parent model/table already exists (run its generator first if it doesn't)

When these assumptions don't hold, edit the `setup` block in the generated test file to match the parent's actual requirements.

### `--parent` controller generation

When `--parent=Organizations::Organization` is passed, the generated controller includes nesting configuration:

```ruby
module Organizations
  class MembershipsController < Organizations::ApplicationController
    include Core::Common

    self.parent_class = "Organizations::Organization"
    self.parent_param = :organization_id
    self.parent_association = :memberships
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:membership).permit(:role, :user_id)
    end

    def allowed_order_columns
      %w[id role created_at updated_at]
    end

    def serializer_profile
      { index: {}, show: {}, create: {}, update: {} }
    end
  end
end
```

The parent FK column is automatically excluded from `model_params` — the parent-scoped builder in `Core::Common` handles setting it. The route becomes nested:

```ruby
namespace :organizations do
  resources :organizations do
    resources :memberships, only: %i[index show create update destroy]
  end
end
```

The integration test uses a callable `path:` lambda for dynamic parent ID resolution at test runtime:

```ruby
resource_test path: -> { "/organizations/organizations/#{Organizations::Organization.first.id}/memberships" },
              create_params: -> { { membership: { role: 1 } } },
              update_params: ->(record) { { membership: { role: 2 } } }
```

### Callable path explanation

The `path:` option in `resource_test` accepts a lambda (Proc) that is resolved via `instance_exec` at test runtime through `Core::ResourceTest.resolve_path_for`. This allows dynamic path components like parent IDs that aren't known until tests run. The lambda has access to test instance variables (`@parent`, `@record`) and can call `Model.first.id` or fixture accessors.

### Sensitive attribute filtering

Columns matching sensitive patterns are automatically excluded from `ransackable_attributes`. The `SENSITIVE_ATTRIBUTES` constant checks for these substrings (case-insensitive) in column names:

```
password, token, secret, key, salt, crypt, otp, auth,
credential, ssn, sin, credit, card, cvv, cvc, pin
```

A column named `token_digest`, `api_key`, or `password_hash` would be filtered out.
A column named `ticket_number` or `author_name` would NOT be filtered (no substring match).

The filter applies only to `ransackable_attributes`. Serialized attributes, migrations, and controllers include all columns normally.

### Locale generation

Each generated model gets a locale file at `config/locales/<module>/<model_name>.en.yml` (e.g., `config/locales/events/venue.en.yml`) with success and error message keys used by `Core::JsonResponse#inferred_message_key`:

```yaml
venue:
  success:
    index: "Venues retrieved successfully"
    show: "Venue retrieved successfully"
    create: "Venue created successfully"
    update: "Venue updated successfully"
    destroy: "Venue deleted successfully"
  errors:
    create: "Failed to create venue"
    update: "Failed to update venue"
    destroy: "Failed to delete venue"
```

The key is derived from `model_name.demodulize.underscore` (e.g., `Events::Venue` → `venue`). This matches how `Core::Common` infers the I18n key for response messages. Namespace prefixes are stripped, so two models with the same name in different namespaces share the same locale key.

### `Core::SlugableTest` (`test/support/core/slugable_test.rb`)

A reusable test helper for models using `Core::Slugable`. Generated slugable models include it automatically. Use it in hand-written tests too.

Zero-config (for models without belongs_to or other required attributes):

```ruby
class MyModelTest < ActiveSupport::TestCase
  include Core::SlugableTest

  test_slugable  # generates 3 tests: slug-on-create, duplicate-counter, slug-update
end
```

With `create_params:` (for models with required associations):

```ruby
class MyModelTest < ActiveSupport::TestCase
  include Core::SlugableTest

  test_slugable create_params: -> { { name: "Test", other_required: value } }
end
```

Generates 3 tests:
- **slug-on-create**: Verifies slug is generated from the source column on creation
- **duplicate-counter**: Creates a second record with a trailing-space variant of the same source value, verifies slug gets a `-N` suffix
- **slug-update**: Changes the source column value, verifies slug is regenerated

The duplicate-counter test uses a trailing space on the source value (e.g. `"Name "`) to bypass uniqueness validation, so it always works regardless of whether the model has `validates :name, uniqueness: true`.

## What It Doesn't Do (Intentional Gaps)

These must be added manually after generation:

| Gap | Reason |
|-----|--------|
| **`has_many` / `has_one` associations** | Too context-dependent. `belongs_to` FKs are declared at generation time via column syntax; reverse associations are domain-specific |
| **Custom scopes beyond `alphabetical`** | Business logic is too varied to template |
| **Additive/conditional validation rules** | The generator only produces `validates :name, presence: true`. Add uniqueness, numericality, custom validations manually |
| **Composite indexes** | Only `slug` (unique) indexes are generated. Multi-column indexes must be added by hand |
| **Polymorphic belongs_to** | Not supported by the column parser |
| **Non-UUID primary keys** | Always uses UUID v7 via `uuidv7()` database function |
| **Monetary columns** | No special `cents` handling — use `price_cents:integer` and handle conversion manually |
| **`VISIBILITY` hash population** | The generated policy has `VISIBILITY = {}.freeze`. Role-based attribute/association visibility must be added per domain |
| **`serializer_profile` association `include:` entries** | Empty by default. Add `show: { include: [:association_name] }` to include associations in responses |
| **Destroy test fixture class mapping reversal** | `rails destroy` removes generated files but the `set_fixture_class` entry in `test_helper.rb` may not be cleaned up cleanly |

## Known Limitations

### `add_fixture_class_mapping` dynamic insertion

The method now finds the last mapping inside `set_fixture_class(...)` and inserts the new entry before the closing `)`. No hardcoded sentinel — works for any namespace and any insertion order. The guard `fixture_class_already_mapped?` prevents duplicate insertions.

### Migration timestamp mismatch on destroy

`rails destroy` generates a new timestamp dynamically, which may not match the actual migration file. The old migration may need manual cleanup.

### `sample_all_update_params_erb` updates only the first column

The update_params lambda in generated integration tests only includes the first data column (plus any belongs_to FK refs). Add remaining columns manually for thorough update coverage.

## Checking What the Generator Will Do

```bash
# Preview without creating files
rails generate domain_module Events::Event name:string --no-interactive --pretend
```

## Relevant Platform Conventions

- All primary keys are UUID v7 (`uuidv7()` DB function)
- Monetary values stored as integers (cents)
- `Core::Common` requires `self.model_class` on the controller
- `skip_authorization` must be called AFTER `include Core::Common`
- `resource_test` generates tests at class-load time by introspecting controller, model, policy, fixtures, and auditable config
- Response messages use I18n keys in `config/locales/en.yml`


