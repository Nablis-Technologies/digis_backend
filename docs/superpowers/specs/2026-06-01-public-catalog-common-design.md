# Public Catalog Common Design

## Goal

Introduce a dedicated read-only abstraction for public catalog endpoints so the app can standardize pagination, ordering, optional search, and explicit per-resource filters across public resources without forcing those endpoints into `Core::Common`'s authenticated CRUD contract.

## Problem

The current public catalog controllers all hand-roll the same `index` and `show` flow:

- build a base relation
- optionally preload attachments
- paginate only when `page` is present
- default to `limit(25)` otherwise
- render a list serializer for `index`
- render a detail serializer for `show`

That pattern currently exists in:

- `Events::CategoriesController`
- `Events::ArtistsController`
- `Events::VenuesController`
- `Organizations::OrganizationsController`

The duplication is small today, but the next iteration will likely add query behavior such as search, resource-specific filters, and allowlisted ordering. If each controller keeps growing independently, the project will accumulate copy-paste query code and drift in public API behavior.

`Core::Common` is not the right abstraction to absorb this. It is already the authenticated CRUD concern for admin and owner-managed resources. Its contract assumes authorization, `policy_scope`, mutation hooks, parent nesting, and `model_params`. Public catalog endpoints are read-only and intentionally do not share that controller lifecycle.

## Recommendation

Adopt a separate `Core::PublicCommon` concern for read-only public catalogs.

This concern should:

- own `index` and `show`
- reuse `Core::Pagination`
- optionally reuse `Core::Filterable`
- standardize shared query params
- leave resource-specific filters explicit in each controller
- keep `Core::FollowableActions` separate

Do not extend `Core::Common` with a public mode. Do not collapse admin CRUD and public catalog reads into one concern.

## Approaches Considered

### 1. Thin `PublicCommon`

Standardize only `index`, `show`, pagination, and serializer selection.

Pros:

- smallest first step
- low implementation risk
- easiest to review

Cons:

- filter/search code still grows separately in each controller
- less helpful once public catalogs become query-heavy

### 2. Declarative `PublicCommon` (recommended)

Standardize read actions, pagination, ordering, optional search, and explicit per-resource filters through a small controller DSL.

Pros:

- good reuse without hiding behavior
- supports future query growth
- keeps public controllers short and readable
- matches the repo's concern-based controller style

Cons:

- slightly more up-front design work than a thin wrapper
- still requires controller-level filter declarations

### 3. `PublicCommon` plus per-resource query objects

Keep the concern very small and move filter/search behavior into classes such as `Events::VenueCatalogQuery`.

Pros:

- excellent long-term separation when query logic becomes complex
- easiest path for richer catalog search later

Cons:

- heavier than the current need
- introduces more files and indirection before the project has proved it needs them

## Solution

### 1. Add `Core::PublicCommon`

Create a new concern at:

- `app/controllers/concerns/core/public_common.rb`

This concern is the shared controller engine for public read-only catalogs. It should not depend on `Core::Authorizable` or `policy_scope`.

Responsibilities:

- load the configured model class
- handle `index`
- handle `show`
- apply a base relation
- apply explicit catalog filters
- optionally apply `q` search
- apply allowlisted ordering
- apply pagination
- render list/detail serializers

### 2. Keep the controller contract explicit

Each controller using `Core::PublicCommon` should declare:

- `self.model_class`
- `self.list_serializer`
- `self.detail_serializer`
- `allowed_order_columns`
- `base_scope`

Optional hooks:

- `detail_scope`
- `searchable?`
- `apply_catalog_filters`
- `default_order_by`
- `default_order_direction`
- `apply_show_scope`

The goal is that a developer can open a public controller and immediately see:

- which model it exposes
- how the list relation is built
- how the detail relation is built
- which sorts are supported
- which filters are supported

### 3. Standard shared query contract

All controllers using `Core::PublicCommon` should share these params:

| Param | Meaning | Required |
|---|---|---|
| `page` | Page number for pagination | no |
| `per_page` | Requested page size, capped by `Core::Pagination#max_per_page` | no |
| `order_by` | Allowlisted column name for sort | no |
| `order_direction` | `asc` or `desc` | no |

Behavior:

- if `page` is present, paginate and return pagination metadata
- if `page` is absent, return `limit(default_per_page)` to preserve current public behavior
- if `order_by` is invalid, fall back to the controller default
- if `order_direction` is invalid, fall back to the controller default

### 4. Hybrid query contract for search and filters

The public API should follow a hybrid model:

- shared params control result shape and navigation
- resource-specific params express domain meaning

Shared optional param:

| Param | Meaning | Availability |
|---|---|---|
| `q` | text search via Ransack | only on controllers that opt into `searchable?` |

Resource-specific params remain explicit per controller.

Initial examples:

| Resource | Resource-specific params |
|---|---|
| venues | `city`, `country`, `verified` |
| artists | `genre`, `verified` |
| categories | none initially |
| organizations | none initially, possibly `q` only |

This avoids inventing a fake universal filter DSL while still giving clients a predictable base contract.

### 5. Filter behavior should be explicit, not inferred

Do not auto-wire request params to model scopes by naming convention.

Example of what to avoid:

- infer that `params[:city]` should call `by_city`
- infer that `params[:verified]` should call `verified`

Although this looks DRY, it creates hidden API behavior and weakens controller readability.

Instead, each controller should explicitly map request params to scope calls inside `apply_catalog_filters`.

Example shape:

```ruby
def apply_catalog_filters(scope)
  scope = scope.by_city(params[:city]) if params[:city].present?
  scope = scope.by_country(params[:country]) if params[:country].present?
  scope = scope.verified if params[:verified] == "true"
  scope
end
```

### 6. Search should be opt-in

`Core::Filterable` currently applies `params[:q]` through Ransack only when a relation supports it. That behavior is appropriate for a first public abstraction, but public controllers should opt into it explicitly.

`Core::PublicCommon` should therefore gate search behind `searchable?`.

Contract:

- default is `false`
- when `true`, `filter_records(scope)` may run
- when `false`, `q` is ignored

This keeps public search intentional and prevents accidental expansion of query capabilities.

### 7. Invalid query behavior

The public contract should fail safely rather than raising `400` for routine bad params.

Rules:

- invalid `order_by` falls back to the controller default
- invalid `order_direction` falls back to the controller default
- unsupported resource-specific filter params are ignored
- malformed `q` / Ransack input falls back to the unfiltered relation, matching current `Core::Filterable` behavior

This preserves the current permissive posture and avoids breaking clients with minor mistakes.

If stricter validation is needed later, it can be introduced deliberately as a separate API contract change.

## Proposed Concern Shape

The concern should be designed around read-only catalogs, not generic CRUD.

Illustrative shape:

```ruby
module Core
  module PublicCommon
    extend ActiveSupport::Concern

    include Core::JsonResponse
    include Core::Pagination
    include Core::Filterable

    included do
      class_attribute :model_class, default: nil
      class_attribute :resource_param, default: :id
      class_attribute :list_serializer, default: nil
      class_attribute :detail_serializer, default: nil

      before_action :set_clazz
      before_action :set_object, only: :show
    end

    def index
      records = base_scope
      records = apply_index_scope(records)
      records = filter_records(records) if searchable?
      records = apply_catalog_filters(records)
      records = apply_ordering(records)

      total_count = records.count if paginated_request?
      records = paginated_request? ? apply_pagination(records) : records.limit(default_per_page)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil

      render_success(
        data: records,
        serializer_options: { serializer: self.class.list_serializer },
        pagination: pagination
      )
    end

    def show
      record = apply_show_scope(@obj)
      render_success(
        data: record,
        serializer_options: { serializer: self.class.detail_serializer }
      )
    end
  end
end
```

The final implementation does not need to match this example exactly. The important contract is:

- separate list and detail serializers
- separate list and detail scopes
- explicit filters
- optional search
- shared pagination and ordering

## Controller Examples

### `Events::CategoriesController`

Expected shape:

- include `Core::PublicCommon`
- declare category model and public serializers
- set `base_scope` to `Events::Category.active`
- allow simple ordering such as `id`, `name`, `created_at`
- optionally enable `q`

This should be the first migration target because it is the simplest public catalog and has no follow actions.

### `Events::ArtistsController`

Expected shape:

- include `Core::PublicCommon`
- keep `Core::FollowableActions`
- `base_scope` uses `Events::Artist.active.with_attached_profile`
- `detail_scope` uses `Events::Artist.with_attached_profile`
- resource-specific filters may include `genre` and `verified`
- allowlisted ordering should include at least `id`, `name`, `created_at`

### `Events::VenuesController`

Expected shape:

- include `Core::PublicCommon`
- keep `Core::FollowableActions`
- `base_scope` uses `Events::Venue.active.with_attached_profile.with_attached_photos`
- `detail_scope` uses `Events::Venue.with_attached_profile.with_attached_photos`
- resource-specific filters include `city`, `country`, `verified`
- allowlisted ordering should include at least `id`, `name`, `city`, `country`, `created_at`

### `Organizations::OrganizationsController`

Expected shape:

- include `Core::PublicCommon`
- keep `Core::FollowableActions`
- `base_scope` uses `Organizations::Organization.with_attached_profile`
- `detail_scope` uses `Organizations::Organization.with_attached_profile`
- no resource-specific filters initially
- may opt into `q`
- allowlisted ordering should include at least `id`, `name`, `slug`, `created_at`

## Non-Goals

This design intentionally does not do the following:

- extend `Core::Common` with flags like `public_mode`, `read_only`, or `skip_authorization`
- move follow/unfollow/followers into `Core::PublicCommon`
- infer request params from model scopes automatically
- introduce query objects immediately
- define a universal filter language for all public resources
- add public create/update/destroy behavior

## Testing Strategy

### 1. Concern-level tests

Add focused tests for `Core::PublicCommon` behavior. These should verify:

- `index` uses `base_scope`
- `show` loads through `detail_scope`
- `searchable?` gates `q`
- `apply_catalog_filters` composes on top of the incoming relation
- ordering only accepts allowlisted columns
- invalid ordering falls back to defaults
- pagination metadata matches current public behavior

The concern tests should prove the abstraction contract once so each migrated controller does not need to re-prove generic controller mechanics.

### 2. Controller-level integration tests

Existing public endpoint tests should continue verifying:

- success responses
- response shape
- serializer-specific fields
- attachment-backed URLs and nested payloads

New integration tests should cover query behavior where supported:

- allowed ordering
- resource-specific filters
- optional `q`

The compatibility bar is unchanged API responses for existing requests that do not use new query params.

## Migration Plan

### Phase 1: Introduce the concern

Add `Core::PublicCommon` and its concern-level tests without migrating all controllers at once.

### Phase 2: Migrate the simplest controller first

Migrate `Events::CategoriesController` first.

Reason:

- no followable actions
- smallest query surface
- lowest attachment complexity

This is the best controller to validate whether the abstraction feels natural.

### Phase 3: Migrate the remaining public catalogs

Then migrate:

1. `Events::ArtistsController`
2. `Events::VenuesController`
3. `Organizations::OrganizationsController`

That order grows complexity gradually:

- artists add follow actions and profile attachments
- venues add more filters and richer attachment loading
- organizations confirm the abstraction works outside the events namespace

### Phase 4: Reassess complexity

After all four controllers are migrated, reassess whether any controller's query logic has become large enough to justify extraction into a per-resource query object.

Examples of extraction candidates:

- `Events::VenueCatalogQuery`
- `Events::ArtistCatalogQuery`
- `Organizations::OrganizationCatalogQuery`

Do not introduce these objects before there is proven complexity.

## Affected Files

Expected implementation surface:

| File | Change |
|---|---|
| `app/controllers/concerns/core/public_common.rb` | new concern |
| `app/controllers/events/categories_controller.rb` | migrate to `Core::PublicCommon` |
| `app/controllers/events/artists_controller.rb` | migrate to `Core::PublicCommon` |
| `app/controllers/events/venues_controller.rb` | migrate to `Core::PublicCommon` |
| `app/controllers/organizations/organizations_controller.rb` | migrate to `Core::PublicCommon` |
| `test/controllers` or `test/integration` public endpoint files | update/add query coverage |
| concern test file for `Core::PublicCommon` | add shared behavior tests |

Potential supporting edits:

| File | Change |
|---|---|
| `app/controllers/concerns/core/filterable.rb` | no intended contract change; confirm search gating remains concern-controlled |
| `app/controllers/concerns/core/pagination.rb` | no intended contract change; confirm default ordering/fallbacks fit the public contract |
| API docs / Postman collection | document shared and per-resource public query params |

## Open Questions Resolved In This Spec

- Use a separate public concern rather than extending `Core::Common`: yes
- Standardize query params fully across catalogs: no
- Use a hybrid contract with shared pagination/sort and explicit resource filters: yes
- Introduce query objects immediately: no
- Keep follow actions separate from the public catalog concern: yes

## Success Criteria

This design is successful if:

- public catalog controllers become declarative and materially smaller
- pagination and ordering behavior is consistent across public catalogs
- query behavior remains explicit and readable
- `Core::Common` remains focused on authenticated CRUD
- new public catalogs can be added without re-copying `index/show` controller mechanics
- the app can add search and domain filters without drifting into four separate controller patterns
