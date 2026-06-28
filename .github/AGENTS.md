# Project Agent Instructions (ALWAYS FOLLOW)

## AI Coding Assistant Guidelines for Digis Backend — Event Ticketing Platform

## Project Overview

This is `digis_backend`, a Rails application for an event ticketing platform targeting the Ethiopia market. It features phone-first identity, organizer management, ticket QR/offline scanning, short URL system (dig.is), configurable fee/commission engine, multi-currency diaspora checkout, on-site box office sales, invoicing, and SMS/email campaign billing.

## Workflow Orchestration

### 1. Plan Mode Default

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately - don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### Plan Directory (Canonical)

- Canonical plan directory for this repository: `docs/superpowers/plans/`
- Atlas and Prometheus MUST persist every generated/revised plan to this directory.
- Plans must never exist only in session/chat output; the authoritative source is the plan file on disk.
- If plan location ever changes, update this section first and then align all agent files.

### 2. Subagent Strategy

- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop

- After ANY correction from the user: update tasks/lessons.md with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done

- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes - don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests - then resolve them
- Zero context switching required from the user

### Core Principles

No Laziness: Find root causes. No temporary fixes. Senior developer standards.
Minimal Impact: Changes should only touch what's necessary. Avoid introducing bugs.

## Architecture Patterns

### Modular Monolith Structure

This is a **modular monolith** Rails application. Each module is a self-contained domain with explicit dependencies:

| Module | Purpose | Dependencies |
|--------|---------|--------------|
| `Core` | Shared infrastructure (auth, RBAC, concerns, base services) | None |
| `Events` | Event management, venues, scheduling | `Core` |
| `Ticketing` | Ticket types, inventory, QR codes, scanning | `Core`, `Events` |
| `Orders` | Checkout, payments, fees, invoices | `Core`, `Ticketing` |
| `Organizations` | Orgs, memberships, roles | `Core` |
| `Messaging` | SMS/email campaigns, credits, billing | `Core` |
| `BoxOffice` | On-site sales, will-call, guest lists | `Core`, `Ticketing`, `Orders` |
| `ShortUrls` | dig.is link management, analytics | `Core` |

### Module Conventions

- **Namespace**: Each module uses its own namespace (e.g., `Events::Event`, `Ticketing::Ticket`)
- **Core namespace**: `Core::*` for platform-level reusable features (auth, RBAC, concerns, base services)
- **Table naming**: Prefixed with module name (e.g., `core_users`, `events_events`, `ticketing_tickets`)
- **Base classes**: Each module has its own base classes that inherit from `Core::*`
  - `Events::ApplicationRecord < Core::ApplicationRecord`
  - `Events::ApplicationController < Core::ApplicationController`
- **Cross-module dependencies**: Explicit and documented. Modules only depend on `Core` + specific other modules
- **No circular dependencies**: If Module A depends on Module B, Module B cannot depend on Module A

### Rails Application Structure

- **Core module**: `Core::*` for shared infrastructure
- **Domain modules**: `Events::*`, `Ticketing::*`, `Orders::*`, etc.
- **Monetization**: All monetary values stored as integers (cents)

### Model Patterns

- **UUID primary keys**: All tables use `uuidv7()` for IDs
- **Ransack integration**: Always implement `ransackable_attributes` and `ransackable_associations`
- **Status fields**: Use string columns with validated sets (not enums) for flexibility
- **JSONB**: Use for flexible configuration, conditions, and structured data
- **Polymorphic relationships**: Use `*_type` and `*_id` for flexible associations

### Controller Patterns

- **Base**: Inherit from module's `ApplicationController` (e.g., `Events::ApplicationController < Core::ApplicationController`)
- **Core controllers**: Use `Core::Common`, `Core::Authenticatable`, `Core::Filterable`, `Core::Pagination`
- **Domain controllers**: Use module-specific concerns that inherit from Core concerns
- **Required methods**: Implement `model_params`, `eager_load_config`, `allowed_order_columns`, `serializer_profile`
- **Two-layer serialization**:
  - `eager_load_config` → SQL `.includes()` (no policy gate, per-action with `:default` fallback)
  - `serializer_profile[:include]` → AMS rendering (policy-gated via `VISIBILITY`)
  - `serializer_profile[:fields]` → Attribute visibility (intersected with policy `VISIBILITY[:fields]`)
  - See `docs/SERIALIZER_PROFILE_AND_VISIBILITY.md` for full documentation
- **JSON responses**: Use `render_success`/`render_error` from `Core::JsonResponse`
- **Audit logging**: Include `Core::AuditableController` for change tracking
- **Review workflows**: Include `Core::ReviewableController` for approval workflows

### Service Patterns

- **Location**: `app/services/{module}/` (e.g., `app/services/core/`, `app/services/events/`)
- **Naming**: `*Service` suffix (e.g., `AuthService`, `FeeCalculator`)
- **Structure**: Accept dependencies in constructor, provide public methods
- **Transactions**: Wrap complex operations in `ActiveRecord::Base.transaction`
- **Result objects**: Return `Result.success(value)` or `Result.failure(error)`
- **Cross-module services**: Domain services can call Core services, but not vice versa

### External Dependencies

- **Authentication**: JWT with refresh token rotation (`Core::TokenService`, `Core::AuthService`)
- **JSON Response**: `Core::JsonResponse` provides `render_success`/`render_error`
- **CRUD Operations**: `Core::Common` provides standard index/show/create/update
- **Filtering**: `Core::Filterable` enables Ransack-based filtering
- **Pagination**: Built-in with `page`, `per_page`, `order_by`, `order_direction` params
- **Serialization**: ActiveModel Serializers with two-layer config — `eager_load_config` (SQL preloading) and `serializer_profile` (AMS rendering, policy-gated via `VISIBILITY` — see `docs/SERIALIZER_PROFILE_AND_VISIBILITY.md`)
- **Authorization**: Pundit policies in `app/policies/{module}/`

## Development Workflows

### Domain Module Generator — Token-Saving Strategy

**Use the generator FIRST, then surgically edit.** The domain module generator (at `lib/generators/domain_module/`) produces ~90% of what a new model needs in one shot — migration, model, controller, serializer, policy, locale, fixtures, integration test, and route. This saves massive tokens because the AI doesn't write convention boilerplate (ransack config, Pundit policy, AMS serializer, `Core::ResourceTest`, locale keys, etc.).

**Default workflow for any new domain model:**

```bash
# 1. Generate the full skeleton
rails generate domain_module Events::Venue name:string description:text \
  'organizer:belongs_to[Organizations::Organizer]' --auditable --slug \
  --no-interactive 2>&1

# 2. Read the generated files
cat app/models/events/venue.rb
cat app/controllers/events/venues_controller.rb
cat test/integration/events/venues_test.rb

# 3. Surgically edit: add business logic, custom validations,
#    has_many associations, extra controller actions, etc.
```

**Key flags for AI agent use:**

| Flag | Purpose |
|------|---------|
| `--no-interactive` | **Always use this** for scripting. Suppresses all prompts. |
| `--auditable` / `--no-auditable` | Default: `false` (opt-in). Add when the model needs change tracking. |
| `--slug` | Adds slug column + unique index + `Core::Slugable` concern. |
| `--slug-source=COL` | Source column for slug (defaults to `name`). Implies `--slug`. |
| `--only=COMPONENTS` | Generate only specific files. Valid: `migration, model, controller, serializer, policy, locale, fixture, integration_test, route`. |
| `--skip=COMPONENTS` | Exclude specific files. Cannot combine with `--only`. |
| `--skip-tests` | Skip test/fixture generation (useful for data-only models). |
| `--pretend` | Preview what would be generated without creating files. |

**Post-generation checklist — the 20% the generator doesn't do:**

1. **Model** (`app/models/...`): Add `has_many`/`has_one` associations, custom scopes, extra validations (uniqueness, numericality), business logic methods, callbacks
2. **Controller** (`app/controllers/...`): Add custom actions beyond CRUD, update `serializer_profile` with fields + includes, add `eager_load_config` for SQL preloading, update `allowed_order_columns`
3. **Policy** (`app/policies/...`): Add `VISIBILITY` hash (required on all policies — use explicit `include:` and `fields:` for every action; use `:all` sentinel for pass-through, e.g. `admin: { include: :all, fields: :all }`), customize `Scope` class for data scoping. Absent keys resolve to `[]` (block), so every action must be explicit.
4. **Serializer** (`app/serializers/...`): Remove unnecessary `belongs_to` associations (they cause deep nesting), add custom attribute methods
5. **Test** (`test/integration/...`): If `belongs_to` parent lacks a `name` column, edit the `setup` block — change `create!(name: "Setup ...")` to match the parent's actual column
6. **Migration**: Add composite indexes, FK constraints, or column defaults if needed

**Important conventions:**
- `--no-interactive` with `--auditable` or `--slug` works fully. `--slug-source` exits non-zero if you omit the value — always pass it: `--slug-source=code`
- The generator assumes parent models exist. Generate parent models first.
- Self-referential `belongs_to` (e.g. `event:belongs_to[Events::Event]`) gets `optional: true` automatically.
- `rails destroy domain_module Module::Name` reverses everything. Migration cleanup may be manual due to timestamp mismatch.

**Full docs:** `docs/DOMAIN_MODULE_GENERATOR.md`

All agents MUST follow the project's RuboCop configuration (`.rubocop.yml`):

- After making code changes, run:
  ```
  bundle exec rubocop
  ```
- Prefer safe auto-corrections:
  ```
  bundle exec rubocop -A
  ```
- Fix ALL offenses in changed files
- If an offense cannot be fixed safely, document the reason with a narrowly-scoped TODO

### Testing

- **Framework**: Minitest with fixtures
- **Location**: `test/` directory (models, services, integration, jobs)
- **Fixtures**: `test/fixtures/` with YAML files
- **Parallel testing**: Enabled with `parallelize(workers: :number_of_processors)`
- **Test helpers**: Auto-loaded from `test/support/**/*.rb` — includes reusable auth, CRUD, pagination, audit, and slugable test modules
- **Integration tests**: Generated automatically by the domain module generator using `Core::ResourceTest` — covers CRUD, authorization, audit logging, pagination, filtering, ordering, and attribute visibility. These are the PRIMARY tests.
- **Model tests**: NOT generated. Write them manually in `test/models/` for business logic, custom validations, scopes, and instance methods that aren't covered by integration tests.

### Test Guidelines

1. **Integration tests** — The generator produces a `Core::ResourceTest`-based integration test that covers authorization, CRUD, audit logging, pagination, filtering, ordering, and attribute visibility. Run `rails test` to verify generated tests pass before adding custom logic.
2. **Model tests** — Write manually in `test/models/` for business logic not covered by integration tests (custom validations, scopes, instance methods, state machines). Use `test` blocks with standard assertions.
3. **Slugable tests** — Include `Core::SlugableTest` + `test_slugable` in any model test for slugable models. Generates 3 tests automatically.
4. **Fixtures** — Leverage YAML fixtures for test data. Integration tests load domain fixtures for read-only operations.
5. **Test edge cases** — nil values, empty strings, boundary conditions.

### Database Conventions

- **Migrations**: Use `uuidv7()` for primary keys, comprehensive indexing
- **Precision**: Use integer (cents) for monetary amounts, not decimals
- **Foreign keys**: Explicitly declare all foreign key constraints
- **JSONB**: Use for flexible data (conditions, configurations, metadata)
- **Indexes**: Always index foreign keys, status fields, and frequently queried columns
- **Check constraints**: Use database-level constraints where possible (e.g., capacity checks)

### Implementation Rules - No Backward Compatibility / Zero Debt

- This project is NOT in production yet. There is **zero need** for backward compatibility.
- When replacing or upgrading a feature: **completely remove** the old code, old files, old functions, old routes, etc.
- For database changes: **Never create a new migration file** for existing tables. Instead, **edit the original migration file** that created/altered the table, then re-run migrations.
- Leaving backward compatibility or unused code/files creates technical debt. Always clean up completely.
- Prioritize clean, minimal, modern code. Delete first, then implement the new version.

### Key Commands

```bash
# Run tests
bin/rails test

# Run a specific test file
bin/rails test test/models/core/user_test.rb

# Generate a domain module (saves tokens — generates 10 files at once)
bin/rails generate domain_module Events::Venue name:string --no-interactive

# Preview what a generator will create (no files written)
bin/rails generate domain_module Events::Venue name:string --no-interactive --pretend

# Destroy a generated domain module
bin/rails destroy domain_module Events::Venue --no-interactive

# Run RuboCop
bundle exec rubocop

# Run RuboCop with auto-fix
bundle exec rubocop -A

# Database operations
bin/rails db:migrate
bin/rails db:rollback
bin/rails db:seed
```

**N+1 detection:** Enabled globally in `test` environment via `config.active_record.strict_loading_by_default = true`. Any lazy-loaded association on a query-loaded record raises `ActiveRecord::StrictLoadingViolationError`. Fix with `.includes(:association)`.

### Critical Files to Reference

- `app/models/core/user.rb` — Phone-first identity, RBAC, permission checking
- `app/services/core/auth_service.rb` — JWT auth, refresh token rotation
- `app/services/core/token_service.rb` — Token generation and payload building
- `app/controllers/concerns/core/common.rb` — CRUD operations pattern
- `app/controllers/concerns/core/auditable_controller.rb` — Audit logging
- `app/controllers/concerns/core/reviewable_controller.rb` — Review workflows
- `app/models/concerns/core/user_authenticatable.rb` — Auth concern
- `app/models/concerns/core/auditable_model.rb` — Audit concern
- `app/models/concerns/core/reviewable_model.rb` — Review concern
- `db/schema.rb` — Current database state
- `docs/DOMAIN_MODULE_GENERATOR.md` — Full generator docs (read before using)
- `docs/SERIALIZER_PROFILE_AND_VISIBILITY.md` — Two-layer serialization: SQL preloading vs AMS rendering, policy VISIBILITY integration, `:all` sentinel
- `docs/EVENT PLATFORM ARCHITECTURE REVIEW AND REDESIGN.md` — Complete architecture spec
- `docs/PLATFORM COMPREHENSIVE CODE REVIEW.md` — Code review findings
- `config/routes.rb` — Routing patterns
- `test/support/core/resource_test.rb` — Reusable integration test DSL (generated tests use this)
- `test/support/core/auth_test_helpers.rb` — Reusable auth token/headers for integration tests
- `test/support/core/crud_test_helpers.rb` — Reusable CRUD assertions
- `test/support/core/pagination_test_helpers.rb` — Reusable pagination/filtering/ordering assertions
- `test/support/core/audit_test_helpers.rb` — Reusable audit log assertions
- `test/support/core/slugable_test.rb` — Reusable slugable model tests
- `docs/TEST_HELPERS_GUIDE.md` — Full documentation for test support modules

### Test Support Modules

Reusable test helpers live in `test/support/core/` and are auto-loaded via `Dir["test/support/**/*.rb"]` in `test_helper.rb`.

Include them in integration tests:
```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers  # provides admin_headers, user_headers
  include Core::CrudTestHelpers  # provides assert_index, assert_create, etc.
  include Core::PaginationTestHelpers  # provides assert_pagination_works, etc.
  include Core::AuditTestHelpers  # provides assert_audit_logged, etc.
end
```

Available helpers:

**Auth** (`Core::AuthTestHelpers`):
- `admin_headers` — Bearer token for `super_admin` fixture user
- `user_headers` — Bearer token for `attendee` fixture user

**CRUD** (`Core::CrudTestHelpers`):
- `assert_index(resource_path, headers:)` — GET, assert success
- `assert_show(resource_path, record, headers:, check_attributes:)` — GET :id, assert success
- `assert_create(resource_path, params, headers:, check_attributes:)` — POST, assert created
- `assert_create_forbidden(resource_path, params, headers:)` — POST, assert 403
- `assert_update(resource_path, record, params, headers:, check_attributes:)` — PATCH, assert success
- `assert_update_forbidden(resource_path, record, params, headers:)` — PATCH, assert 403
- `assert_destroy(resource_path, record, headers:)` — DELETE, assert success
- `assert_destroy_forbidden(resource_path, record, headers:)` — DELETE, assert 403
- `assert_resource_deleted(model_class, record)` / `assert_resource_not_deleted(model_class, record)`

**Pagination** (`Core::PaginationTestHelpers`):
- `assert_pagination_works(resource_path, headers:, per_page:)` — GET with page params
- `assert_filtering_works(resource_path, filter_params:, headers:, check:)` — GET with Ransack query
- `assert_ordering_works(resource_path, order_by:, direction:, headers:)` — GET with sort params

**Audit** (`Core::AuditTestHelpers`):
- `assert_audit_logged(action:, auditable:, actor:)` — Assert audit log exists
- `assert_audit_not_logged(action:, auditable:)` — Assert audit log absent
- `assert_audit_log_count(action:, auditable:, expected:)` — Assert exact count

### Module Directory Structure

```
app/
  models/
    core/              # Shared infrastructure models
    events/            # Event domain models
    ticketing/         # Ticket domain models
    orders/            # Order/payment domain models
    organizations/     # Organization domain models
    messaging/         # Messaging domain models
    box_office/        # Box office domain models
    short_urls/        # Short URL domain models
  controllers/
    core/              # Core controllers
    events/            # Event controllers
    ticketing/         # Ticket controllers
    ...
  controllers/concerns/
    core/              # Shared controller concerns
  services/
    core/              # Core services
    events/            # Event services
    ticketing/         # Ticket services
    ...
  policies/
    core/              # Core policies
    events/            # Event policies
    ticketing/         # Ticket policies
    ...
  serializers/
    core/              # Core serializers
    events/            # Event serializers
    ticketing/         # Ticket serializers
    ...
```
