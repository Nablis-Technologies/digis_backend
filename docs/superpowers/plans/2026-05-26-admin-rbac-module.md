# Admin RBAC Module Implementation Plan

> **Requires:** subagent-driven-development or inline execution.

**Goal:** Build `Admin::` namespace with user/role/permission CRUD, nested role assignment, three-tier hierarchy (SUPPORT/CORE_ADMIN/SUPER_ADMIN), soft deactivation, audit logging.

**Approach:** Pundit array-namespace pattern (`authorize([:admin, record])`) on `Admin::ApplicationController`. No `policy_class`/`authorize_record`/`scope_records` helpers.

**Order:** Each step depends on previous. Steps 1-4 are prerequisites; 5-6 are infrastructure; 7-12 build the module; 13-14 test it.

---

## Implementation Steps

### Step 1: Migration
- **File:** `db/migrate/*_add_deactivated_at_to_core_users.rb` ✅ Created above
- `add_column :core_users, :deactivated_at, :datetime` + index
- `add_column :core_users, :deactivated_reason, :string`
- Run: `bin/rails db:migrate`

### Step 2: Model changes (Core::User)
- **File:** `app/models/core/user.rb`
- Add `active` scope: `where(deactivated_at: nil)`
- Add `deactivated?`: `deactivated_at.present?`
- Add `deactivation_fraud?`: `deactivated_reason == "fraud"`
- Add `deactivated_at` to `ransackable_attributes`
- **Test first:** `test/models/core/user_test.rb` — test scope, helpers

### Step 3: Auth gate
- **Files:** `app/services/core/auth_service.rb`, `app/controllers/concerns/core/authenticatable.rb`
- In `AuthService.authenticate_user`: after finding user, return nil if `user.deactivated?`
- In `AuthService.refresh_access_token`: after finding token, raise `Core::AuthenticationError.new("Account deactivated", code: "account_deactivated")` if `user.deactivated?`
- In `Authenticatable#refresh_token`: re-raise `result.error` instead of swallowing it (currently catches and returns nil)
- **Test first:** `test/integration/core/auth_test.rb` — deactivated login returns 401, deactivated refresh returns `account_deactivated`

### Step 4: Vocabulary normalization
- **Files:** `app/policies/core/application_policy.rb`, `db/seeds.rb`
- `ApplicationPolicy#user_role_key`: add `CORE_ADMIN` check alongside `ADMIN`
- `Seeds`: add `CORE_ADMIN` role, `SUPPORT` role, `permission.show` permission, plus `user.deactivate`, `user.reactivate`, `user_role.*`, `permission.show` codes

### Step 5: Core::Common + Admin::ApplicationController
- **Files:** `app/controllers/concerns/core/common.rb`, `app/controllers/concerns/core/json_response.rb`, `app/controllers/admin/application_controller.rb`
- `Core::Common`: add `class_attribute :resource_param, default: :id`, `class_attribute :default_serializer, default: nil`
- `Core::Common#set_object`: use `resource_param` for lookup (instead of hardcoded `:id`), scope through parent
- `JsonResponse#render_success`: merge `default_serializer` into `serializer_options`
- **Create** `app/controllers/admin/application_controller.rb`:
  - Inherit `Core::ApplicationController`
  - Override `authorize(record, ...)`: `super([:admin, record], ...)`
  - Override `policy_scope(scope, ...)`: `super([:admin, scope], ...)`
  - Override `policy(record)`: `super([:admin, record])`

### Step 6: ResourceTest updates
- **File:** `test/support/core/resource_test.rb`
- `Metadata#resolve_policy_class`: check `@options[:policy_class]` first
- `Metadata#resolve_fixture_keys`: filter by `@options[:fixture_keys]` if present
- `Metadata#register_setup_block`: use `@parent_fixture_key` from options
- `perform_request`: accept `meta:` kwarg, use `meta.resource_param` for URL construction if present
- `generate_destroy_test`: use `resource_param` for URL

### Step 7: Seed + Fixture updates
- **Seeds** (`db/seeds.rb`): Add `CORE_ADMIN` (all permissions except `permission.destroy` and `user.destroy`), `SUPPORT` (user.index/show + user.deactivate/role index + audit_log.*), role-permission mappings matching distribution table
- **Fixtures:**
  - `test/fixtures/core_roles.yml`: add SUPPORT role
  - `test/fixtures/core_permissions.yml`: add 19 permission entries
  - `test/fixtures/core_role_permissions.yml`: add CORE_ADMIN + SUPPORT mappings (14 entries)
  - `test/fixtures/core_user_roles.yml`: add `attendee_support` entry

### Step 8: Policies
- **Create:** `app/policies/admin/user_policy.rb`
  - `Scope`: `user.index` permission check
  - `show?/create?/update?`: SUPPORT+ can show; CORE_ADMIN+ can create/update
  - `deactivate?`: ALL admin tiers (SUPPORT+)
  - `reactivate?`: CORE_ADMIN+, but not if `deactivation_fraud?` (SUPER_ADMIN only)
- **Create:** `app/policies/admin/role_policy.rb`
  - `Scope`: `role.index` permission
  - Full CRUD for CORE_ADMIN+ 
- **Create:** `app/policies/admin/permission_policy.rb`
  - `index`/`show`: CORE_ADMIN+
  - `create`/`update`/`destroy`: SUPER_ADMIN only
- **Create:** `app/policies/admin/user_role_policy.rb`
  - `index`/`create`/`destroy`: CORE_ADMIN+ but `assignable_role?` check limits to USER/SUPPORT if CORE_ADMIN
  - `Scope`: `user_role.index` permission

### Step 9: Serializer
- **Create:** `app/serializers/admin/user_serializer.rb` — uses `AttributeVisibilitySerializer`, exposes id/email/phone/verified_at/deactivated_at/deactivated_reason/roles

### Step 10: Controllers
- **Create:** `app/controllers/admin/users_controller.rb` — overrides `index` to apply `.active` by default, adds `deactivate`/`reactivate` custom actions
- **Create:** `app/controllers/admin/roles_controller.rb` — standard CRUD via Core::Common
- **Create:** `app/controllers/admin/permissions_controller.rb` — standard CRUD via Core::Common
- **Create:** `app/controllers/admin/user_roles_controller.rb` — nested under users, `resource_param = :role_id`, `auditable_record_for :destroy`

### Step 11: Routes
- **File:** `config/routes.rb`
- `namespace :admin` block with resources for users, roles, permissions; nested user roles

### Step 12: Integration Tests
- **Create:** `test/integration/admin/users_test.rb`
- **Create:** `test/integration/admin/roles_test.rb`
- **Create:** `test/integration/admin/permissions_test.rb`
- **Create:** `test/integration/admin/user_roles_test.rb`
- Each uses `resource_test` DSL with `policy_class:`, `fixture_keys:`, custom params

### Step 13: Auth Regression Tests
- **Create:** `test/integration/auth/deactivated_user_test.rb`
- Deactivated login returns `invalid_credentials`
- Deactivated refresh returns `account_deactivated`
- Active user unaffected
