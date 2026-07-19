# AI Coding Assistant Guidelines for Digis Backend — Event Ticketing Platform

## Project Overview

This is `digis_backend`, a Rails application for an event ticketing platform targeting the Ethiopia market. Key features include:

- **Phone-first identity** — OTP verification, shadow accounts for frictionless ticket purchase
- **Organizer management** — Users belong to Organizations via Memberships with roles (owner/admin/member)
- **Ticket QR/offline scanning** — Device registration, offline queue, sync on reconnect
- **Short URL system** — dig.is with analytics (Cloudflare Workers + KV)
- **Configurable fee engine** — Hierarchical rules (Global → Org → Event → Ticket), multiple absorption models
- **Multi-currency diaspora checkout** — USD/EUR/GBP buyers, FX rates, gift flow
- **On-site box office** — Cashier sessions, will-call, guest lists, offline terminals
- **Invoicing system** — Corporate billing, partial payments, credit notes, recurring invoices
- **SMS/Email campaigns** — Pay-per-message pricing, volume tiers, prepaid credits
- **RBAC** — Roles, permissions, hierarchical access control

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
- **Status fields**: Use string columns with validated sets (not enums)
- **JSONB**: Use for flexible configuration, conditions, metadata
- **Monetary values**: Store as integers (cents), never decimals
- **Module isolation**: Models only reference other models within their module or `Core`

### Controller Patterns

- **Base**: Inherit from module's `ApplicationController` (e.g., `Events::ApplicationController < Core::ApplicationController`)
- **Core controllers**: Use `Core::Common`, `Core::Authenticatable`, `Core::Filterable`, `Core::Pagination`
- **Domain controllers**: Use module-specific concerns that inherit from Core concerns
- **Required methods**: `model_params`, `eager_load_config`, `allowed_order_columns`, `serializer_profile`
- **Two-layer serialization** (see `docs/SERIALIZER_PROFILE_AND_VISIBILITY.md`):
  - `eager_load_config` → SQL `.includes()` (no policy gate)
  - `serializer_profile[:include]` → AMS rendering (policy-gated via `VISIBILITY`)
  - `serializer_profile[:fields]` → Attribute visibility (intersected with policy)
- **JSON responses**: `render_success`/`render_error` from `Core::JsonResponse`
- **Audit logging**: Include `Core::AuditableController`
- **Review workflows**: Include `Core::ReviewableController`

### Service Patterns

- **Location**: `app/services/{module}/` (e.g., `app/services/core/`, `app/services/events/`)
- **Naming**: `*Service` suffix
- **Structure**: Constructor accepts dependencies, public methods for operations
- **Transactions**: Wrap complex operations in `ActiveRecord::Base.transaction`
- **Result objects**: Return `Result.success(value)` or `Result.failure(error)`
- **Cross-module services**: Domain services can call Core services, but not vice versa

### External Dependencies

- **Authentication**: JWT with refresh token rotation (`Core::TokenService`, `Core::AuthService`)
- **JSON Response**: `Core::JsonResponse` provides `render_success`/`render_error`
- **CRUD Operations**: `Core::Common` provides standard index/show/create/update
- **Filtering**: `Core::Filterable` enables Ransack-based filtering
- **Pagination**: Built-in with `page`, `per_page`, `order_by`, `order_direction` params
- **Serialization**: ActiveModel Serializers with two-layer config — `eager_load_config` (SQL preloading) and `serializer_profile` (AMS rendering, policy-gated via `VISIBILITY`)
- **Authorization**: Pundit policies in `app/policies/{module}/`
- **Policy visibility**: Every policy must define an explicit `VISIBILITY` hash with `include:` and `fields:` per action. Use `:all` sentinel for pass-through (e.g. `admin: { include: :all, fields: :all }`). Absent keys resolve to `[]` (block), so every action/role must be explicit.

## Testing

- **Framework**: Minitest with fixtures
- **Location**: `test/` directory
- **Fixtures**: `test/fixtures/` with YAML files
- **Parallel testing**: Enabled
- **Every model MUST have a test**
- **Module isolation**: Test each module independently; mock cross-module dependencies
- **Test naming**: `test/models/core/user_test.rb`, `test/services/events/event_service_test.rb`

### Test Guidelines

1. Test all validations — presence, uniqueness, numericality, inclusion
2. Test all associations — belongs_to, has_many, has_one
3. Test all scopes — every named scope must have coverage
4. Test custom methods — any custom instance/class methods
5. Use fixtures — leverage YAML fixtures for test data
6. Test edge cases — nil values, empty strings, boundary conditions

## Database Conventions

- **Migrations**: Use `uuidv7()` for primary keys, comprehensive indexing
- **Monetary**: Integer (cents) for all money values
- **Foreign keys**: Explicitly declare all constraints
- **JSONB**: Use for flexible data (conditions, configurations, metadata)
- **Indexes**: Always index foreign keys, status fields, frequently queried columns

## Implementation Rules - No Backward Compatibility / Zero Debt

- This project is NOT in production yet. There is **zero need** for backward compatibility.
- When replacing or upgrading a feature: **completely remove** the old code, old files, old functions, old routes, etc.
- For database changes: **Never create a new migration file** for existing tables. Instead, **edit the original migration file** that created/altered the table, then re-run migrations.
- Leaving backward compatibility or unused code/files creates technical debt. Always clean up completely.
- Prioritize clean, minimal, modern code. Delete first, then implement the new version.

## Key Commands

```bash
# Run tests
bin/rails test

# Run a specific test file
bin/rails test test/models/core/user_test.rb

# Run tests with verbose output
bin/rails test -v

# Generate migration
bin/rails generate migration CreateEventsEvent

# Generate model
bin/rails generate model Events::Event name:string status:string

# Generate controller
bin/rails generate controller Events::Events

# Run RuboCop
bundle exec rubocop

# Run RuboCop with auto-fix
bundle exec rubocop -A

# Database operations
bin/rails db:migrate
bin/rails db:rollback
bin/rails db:seed
```

## Critical Files to Reference

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
- `docs/EVENT PLATFORM ARCHITECTURE REVIEW AND REDESIGN.md` — Complete architecture spec
- `docs/PLATFORM COMPREHENSIVE CODE REVIEW.md` — Code review findings
- `config/routes.rb` — Routing patterns
- `docs/SERIALIZER_PROFILE_AND_VISIBILITY.md` — Two-layer serialization system (eager_load_config + serializer_profile + policy VISIBILITY)
- `test/support/core/auth_test_helpers.rb` — Reusable auth token/headers
- `test/support/core/crud_test_helpers.rb` — Reusable CRUD assertions
- `test/support/core/pagination_test_helpers.rb` — Reusable pagination assertions
- `test/support/core/audit_test_helpers.rb` — Reusable audit assertions

### Test Support Modules

Reusable test helpers in `test/support/core/` are auto-loaded via `test_helper.rb`. Include them in integration tests:
```ruby
include Core::AuthTestHelpers
include Core::CrudTestHelpers
include Core::PaginationTestHelpers
include Core::AuditTestHelpers
```

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
