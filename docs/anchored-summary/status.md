# Anchored Summary — Digis Backend

## Goal
- Implement social features (follow system, public serializers, public controllers) and admin CRUD for Venues, Artists, Categories, and Organizations, with integration tests.

## Constraints & Preferences
- Specs in `docs/superpowers/specs/2026-05-28-venues-artists-and-social-features.md`, `2026-05-29-organizations-social-features.md`, and `2026-05-31-admin-organizations-platform-surface.md`
- Owner org routes use path `/organizations/owner` (not `/organizations/organizations`)
- Owner org controller scopes `set_object` and `apply_index_scope` to current user's memberships
- `Core::Common#render_success` already checks `self.class.default_serializer` — no need to override `render_success` to inject a serializer
- Rails 7.1+ `raise_on_missing_callback_actions` = true — callback methods and action methods must be public (not below `private`)
- AMS 0.10.16 uses `instance_eval` for attribute blocks — use `object.` not block params
- Active Storage: always use `Model.with_attached_<name>` to avoid N+1 queries
- Public controllers inherit from `::Public::ApplicationController` (absolute `::` prefix required from Events/Organizations modules)
- Rails 8 strips module prefix from table names — models under `Events::` resolve to `venues`/`artists`; migrations use `events_venues`/`events_artists`, so explicit `self.table_name` required
- `Core::Common` is designed for admin/internal controllers (assumes Pundit auth, policy_scope, full CRUD) — not suitable for public endpoints without heavy override

## Progress
### Done
- Reviewed both social specs — fixed 2 minor cross-reference issues
- Created `Public::ApplicationController`, `Core::Followable`, `Core::SocialLinkable`, `Core::FollowableActions`, `Core::Follow`, `Core::FollowsController`, `Core::FollowPolicy`, `Core::Public::UserSerializer`, `Core::FollowSerializer`
- Created 6 public serializers for Events (CategoryList/Detail, VenueList/Detail, ArtistList/Detail) and 2 for Organizations (OrganizationList/Detail)
- Created 3 admin-policy delegates (`Admin::CategoryPolicy`, `Admin::VenuePolicy`, `Admin::ArtistPolicy`)
- Created Event policies (`Events::VenuePolicy`, `Events::ArtistPolicy`) with follow/unfollow/followers returning `true`
- Rewrote `Events::CategoriesController` — public-only index/show
- Created `Admin::CategoriesController` — full CRUD with Core::Common + Core::AuditableController
- Rewrote `Organizations::OrganizationsController` — public-only index/show
- Created `Organizations::OwnerOrganizationsController` — CRUD with `after_create_hook`, scoped `set_object`/`apply_index_scope`
- Created `Events::VenuesController` and `Events::ArtistsController` — public index/show + FollowableActions
- Created `Admin::VenuesController` and `Admin::ArtistsController` — full CRUD
- Updated all relevant policies, models, serializers, routes
- Ran 4 migrations: venues, artists, follows, org social fields + Active Storage install
- Fixed namespace resolution, serializer block params, N+1 queries, pagination metadata, security (admin policies with `allowed?`), table names, fixture placement
- Created 7 new integration test files for all new endpoints
- Debugged 19 remaining test failures to 0
- **All 700 tests pass at 1393 assertions, 0 failures, 0 errors**
- **Admin Organizations platform surface (complete):**
  - Added seed permissions for `organization.manage_memberships` and `organization.transfer_ownership`
  - Updated CORE_ADMIN/SUPPORT seed/fixtures with org role-permission matrix
  - Created `Admin::OrganizationPolicy` with CRUD + transfer_ownership, custom Scope
  - Created `Admin::MembershipPolicy` with custom `manage_memberships` checks
  - Created `Admin::OrganizationSerializer` with owner, profile_url, memberships_count
  - Created `Admin::OrganizationsController` with CRUD, `after_create_hook` for owner_id, `self.default_serializer = ::Admin::OrganizationSerializer`, `transfer_ownership` action
  - Created `Admin::OrganizationMembershipsController` with parent_class setup and owner-role rejection
  - Added routes for `/admin/organizations` (CRUD + nested memberships + transfer_ownership)
  - Created 2 integration test files — 118 admin org tests
  - Fixed 6 bugs: N+1 on memberships_count, wrong serializer resolution, missing route `:show`, destroy auto-generation param, `render_success` kwarg crash, `Membership` missing `Core::AuditableModel`
- **Owner org endpoint fixes:**
  - Changed routes from `/organizations/organizations` to `/organizations/owner`
  - Added `GET /organizations/owner` (index) and `GET /organizations/owner/:id` (show) — scoped to user's memberships
  - Overrode `set_object` for member-only find (non-members get 404), dropped unnecessary `show` override
  - Replaced `render_success` override with `self.default_serializer` in `Admin::OrganizationsController`
  - Created 14 integration tests (5 new index/show tests)
- **Postman collection restructured** into: Auth, Public, My Account, Admin — with all items fully populated
- **Seed file** updated with org admin permissions, CORE_ADMIN/SUPPORT role matrix

### In Progress
- (none)

### Blocked
- (none)

## Key Decisions
- Owner org routes use `/organizations/owner` (not `/organizations/organizations`) — cleaner path
- `set_object` override scopes show/update/destroy to current user's memberships — non-members get 404 instead of 403
- `apply_index_scope` used instead of policy Scope change — controller-local, doesn't affect other consumers of `Organizations::OrganizationPolicy`
- `self.default_serializer` replaces `render_success` override — `Core::Common` already supports this class attribute
- `Admin::ApplicationController` resolves `Admin::<Model>Policy` via `resolve_admin_policy` for all admin controllers
- Postman collection organized into Auth, Public, My Account, Admin — logical grouping by access level

## Next Steps
1. Verify seed runs cleanly
2. Run full test suite to confirm 0 failures before any new work

## Critical Context
- `Core::JsonResponse#render_success` checks `self.class.default_serializer` before falling through to AMS convention — use this instead of overriding `render_success`
- `before_action :set_object` (from `Core::Common`) must be public — placing it below `private` causes `AbstractController::ActionNotFound` in Rails 7.1+
- Owner org controller overrides `set_object` and `apply_index_scope` only — `show` override was unnecessary because `Core::Common#show`'s re-fetch uses the same ID already scoped by `set_object`
- `Organizations::OrganizationPolicy::Scope` returns `scope.all` — changing it to membership-scoped would affect the admin controller too
- `Organizations::Membership` includes `Core::AuditableModel` — audit job works for membership CRUD
- Test suite: 700 tests, 1393 assertions, 0 failures, 0 errors

## Relevant Files
- `config/routes.rb` — owner org paths changed to `/organizations/owner`; admin org routes with nested memberships + transfer_ownership
- `app/controllers/organizations/owner_organizations_controller.rb` — scoped `set_object`/`apply_index_scope`, `serializer_profile` for index/show
- `app/controllers/admin/organizations_controller.rb` — uses `self.default_serializer = ::Admin::OrganizationSerializer`
- `app/policies/admin/organization_policy.rb` — admin org policy with CRUD + transfer_ownership + Scope
- `app/policies/admin/membership_policy.rb` — admin membership policy with `manage_memberships` checks
- `app/serializers/admin/organization_serializer.rb` — admin serializer with owner, profile_url, memberships_count
- `test/integration/admin/organizations_test.rb` — 56 admin org integration tests
- `test/integration/admin/organization_memberships_test.rb` — 62 admin membership integration tests
- `test/integration/organizations/owner_organizations_test.rb` — 14 owner org tests (with index/show)
- `postman/Digis API_collection.json` — restructured into Auth, Public, My Account, Admin (all items populated)
- `app/controllers/concerns/core/json_response.rb` — `default_serializer` support at line 57-59
