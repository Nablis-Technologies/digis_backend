# Admin RBAC Module

**Date:** 2026-05-26
**Status:** Draft
**Author:** AI-assisted design

## Overview

Build an `Admin::` namespace (following the existing Organizations/Events domain module pattern) that exposes full CRUD for users, roles, and permissions, plus nested role assignment. The module introduces a three-tier admin hierarchy — Support, Core Admin, Super Admin — with granular permission codes, soft deactivation of users, and mandatory audit logging.

---

## 1. Schema Changes

### Migration: `AddDeactivatedAtToCoreUsers`

Add to `core_users`:

| Column | Type | Constraints | Purpose |
|--------|------|-------------|---------|
| `deactivated_at` | `datetime` | nullable | When set, user is soft-deactivated |
| `deactivated_reason` | `string` | nullable, limit 500 | Why the user was deactivated (e.g. `"fraud"`, `"inactive"`, `"user_request"`) |

No index on `deactivated_at` needed unless query analysis shows repeated full scans on the admin users index.

### Model: `Core::User` additions

Default scope:
```ruby
scope :active, -> { where(deactivated_at: nil) }
```

Do **not** set `default_scope` — that would break auth's `find_by(id: payload["user_id"])` for deactivated users trying to authenticate. The `active` scope is used explicitly in `Admin::UsersController#index` only.

Helper methods:
```ruby
def deactivated?
  deactivated_at.present?
end

def deactivation_fraud?
  deactivated? && deactivated_reason&.match?(/\Afraud/i)
end
```

Update `ransackable_attributes` to include `deactivated_at` so admins can filter by it via Ransack:
```ruby
def self.ransackable_attributes(_auth_object = nil)
  %w[id email phone verified_at deactivated_at created_at updated_at]
end
```

---

## 2. Auth Gate

**File:** `app/services/core/auth_service.rb` — `authenticate_user` class method

After `user&.authenticate(password)`, add:

```ruby
return nil if user.deactivated?
```

This prevents deactivated users from logging in or obtaining refresh tokens. The controller already renders `"invalid_credentials"` when `authenticate_user` returns nil — no controller change needed.

Also add a check in `Core::AuthService.refresh_access_token`: reject tokens belonging to a deactivated user. Add after finding the refresh token:

```ruby
raise Core::AuthenticationError.new("Account deactivated", code: "account_deactivated") if user.deactivated?
```

However, there are two layers of error suppression between the raised exception and the client:

1. `Core::AuthService.call` (auth_service.rb:26) catches all `Core::Error` and returns `Result.failure(error)` — the exception never escapes the service.
2. `Authenticatable#refresh_token` (authenticatable.rb:44) then returns `nil` on `result.failure?`.

So even removing the `rescue Core::AuthenticationError` from `refresh_token` is insufficient — the exception is already caught by `AuthService.call`. The `account_deactivated` code never reaches the client.

Fix: `refresh_token` must re-raise the error from the failed result. The controller already has `rescue_from Core::AuthenticationError, with: :handle_authentication_error` registered via `Authenticatable`'s `included do` block, so the propagated error renders the correct code and message:

```ruby
def refresh_token
  refresh_token_value = extract_refresh_token_from_params
  return nil if refresh_token_value.blank?

  result = Core::AuthService.call(
    operation: :refresh_access_token,
    refresh_token_value: refresh_token_value,
    request: request
  )
  raise result.error unless result.success?
  result.value
end
```

---

## 3. Role Vocabulary (normalization)

The existing role landscape has drift between seeds, fixtures, and policy code. Before adding new roles, normalize:

### 3a. Add `CORE_ADMIN` to seeds

`CORE_ADMIN` exists in `test/fixtures/core_roles.yml` (platform core admin) but is absent from `db/seeds.rb`. The seeds' `ADMIN` (org-level admin) is a separate role with a different purpose. Both coexist.

Add to `db/seeds.rb` alongside existing role seeds:

```ruby
core_admin_role = Core::Role.find_or_create_by!(code: "CORE_ADMIN") do |r|
  r.name = "Core Administrator"
  r.description = "Core-level operational access — manages platform resources"
  r.active = true
end
```

### 3b. New `SUPPORT` role

Add to `test/fixtures/core_roles.yml`:

```yaml
support:
  id: 019e5f6a-9999-7def-8cf6-53197a197999
  code: SUPPORT
  name: Support Agent
  description: Platform support — can view users, freeze bad actors, and manage basic support tasks
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>
```

Add to `db/seeds.rb`:

```ruby
support_role = Core::Role.find_or_create_by!(code: "SUPPORT") do |r|
  r.name = "Support Agent"
  r.description = "Platform support — can view users and deactivate accounts"
  r.active = true
end
```

### 3c. Update `Core::ApplicationPolicy#user_role_key`

`app/policies/core/application_policy.rb:53` currently checks only `has_role?("ADMIN")` — the org-level admin. The admin module's platform `CORE_ADMIN` must also resolve to the `:admin` visibility tier:

```ruby
def user_role_key
  return :admin if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
  :default
end
```

---

## 4. Permission Seeds

The existing `db/seeds.rb` is missing `permission.show` (present in the permission distribution table below). Add it along with new codes.

Add to `db/seeds.rb`:

```ruby
{ resource: "user", action: "deactivate", namespace: "core", description: "Deactivate users" },
{ resource: "user", action: "reactivate", namespace: "core", description: "Reactivate deactivated users" },
{ resource: "user_role", action: "index", namespace: "core", description: "List user role assignments" },
{ resource: "user_role", action: "create", namespace: "core", description: "Assign roles to users" },
{ resource: "user_role", action: "destroy", namespace: "core", description: "Revoke roles from users" },
{ resource: "permission", action: "show", namespace: "core", description: "View permission details" },
```

These supplement the existing seeds (which already have `user.{index,show,create,update,destroy}`, `role.{index,show,create,update,destroy}`, `permission.{index,create,update,destroy}` — note `permission.show` is missing and must be added).

### Permission distribution by role

| Code | SUPPORT | CORE_ADMIN | SUPER_ADMIN |
|---|---|---|---|
| `user.index` | ✓ | ✓ | ✓ |
| `user.show` | ✓ | ✓ | ✓ |
| `user.create` | | ✓ | ✓ |
| `user.update` | | ✓ | ✓ |
| `user.deactivate` | ✓ | ✓ | ✓ |
| `user.reactivate` | | ✓ | ✓ |
| `user.destroy` (hard delete) | | | ✓ |
| `role.index` | | ✓ | ✓ |
| `role.show` | | ✓ | ✓ |
| `role.create` | | | ✓ |
| `role.update` | | | ✓ |
| `role.destroy` | | | ✓ |
| `permission.index` | | ✓ | ✓ |
| `permission.show` | | ✓ | ✓ |
| `permission.create` | | | ✓ |
| `permission.update` | | | ✓ |
| `permission.destroy` | | | ✓ |
| `user_role.index` | | ✓ | ✓ |
| `user_role.create` | | ✓ | ✓ |
| `user_role.destroy` | | ✓ | ✓ |

Update the seed's role-permission assignments accordingly. The SUPER_ADMIN role continues to get ALL permissions (including new ones). Add role_permission seeds for SUPPORT and CORE_ADMIN matching the table above.

---

## 5. Core::Common Improvements (Pre-requisite)

Before building the admin module, add two new `class_attribute` declarations to `Core::Common` that solve the admin-specific problems generically and are reusable by any future module.

### 5a. `resource_param`

Allows customizing the URL parameter used for record lookup — needed when the route param is not `:id` (e.g. `:role_id` for nested join records):

```ruby
class_attribute :resource_param, default: :id
```

Core::Common's `set_object` becomes:

```ruby
def set_object
  lookup = self.class.resource_param
  if self.class.parent_class
    @obj = @parent.public_send(child_association)
            .includes(eager_loaded_associations)
            .find_by!(lookup => params[lookup])
  else
    @obj = @clazz.includes(eager_loaded_associations).find_by!(lookup => params[lookup])
  end
end
```

The nested path scopes the lookup through `@parent.public_send(child_association)` — critical for `UserRolesController` where `role_id` is only unique within a `user_id` scope. The existing `.find(params[:id])` already enjoys parent scoping; the same constraint is preserved here.

### 5b. Route `param:` option

The route definition for `UserRolesController` uses Rails' `param:` option to emit `:role_id` instead of `:id` in the URL:

```ruby
resources :roles, only: %i[index create destroy], controller: "user_roles",
          as: :user_roles, param: :role_id
```

This generates URLs like `DELETE /admin/users/:user_id/roles/:role_id` and sets `params[:role_id]` — which Core::Common finds via `self.class.resource_param`.

### 5c. ResourceTest updates

The `resource_test` DSL gains changes in four areas:

**`policy_class:` option** — `Metadata#resolve_policy_class` currently infers policy from model name (`"#{@model_class.name}Policy".constantize`). For `Core::UserRole` this resolves `Core::UserRolePolicy` instead of the correct `Admin::UserRolePolicy`. Fix: check `@options[:policy_class]` first:

```ruby
def resolve_policy_class
  return @options[:policy_class] if @options[:policy_class]
  return @model_class.policy_name.constantize if @model_class.respond_to?(:policy_name)
  "#{@model_class.name}Policy".constantize
end
```

**`resource_param:` option** — four call sites hardcode `record.id` in URL paths. For routes using `param: :role_id` (like nested UserRoles), the URL segment must use `record.role_id` instead. Store `@resource_param = @options[:resource_param]` in Metadata with an `attr_reader`. Then update each call site:

`perform_request` — accepts `meta:` kwarg, uses `meta.resource_param` for the `id` segment:

```ruby
def perform_request(action, path, record:, params:, headers:, meta: nil)
  id = if meta&.resource_param
    record.public_send(meta.resource_param)
  else
    record.respond_to?(:id) ? record.id : "nonexistent"
  end
  case action
  when :index then get path, headers: headers, as: :json
  when :show then get "#{path}/#{id}", headers: headers, as: :json
  when :create then post path, params: params, headers: headers, as: :json
  when :update then patch "#{path}/#{id}", params: params, headers: headers, as: :json
  when :destroy then delete "#{path}/#{id}", headers: headers, as: :json
  end
end
```

The call sites in `generate_tests` and `generate_audit_tests` pass `meta:` — both have access to the Metadata instance. The default `nil` preserves backward compatibility.

`generate_destroy_test` — uses `record.public_send(meta.resource_param)` instead of `record.id`:

```ruby
def generate_destroy_test(meta)
  return unless meta.actions.include?(:destroy)
  permitted_key = meta.fixture_keys.find { |fk| meta.policy_results[fk][:destroy] }
  return unless permitted_key

  test "destroy removes the record" do
    record = if @child_record
      @child_record
    else
      key = meta.param_key
      params = resolve_params(:create, meta, nil)
      meta.model_class.create!(params[key])
    end

    headers = token_headers_for(core_users(permitted_key))
    record_id = meta.resource_param ? record.public_send(meta.resource_param) : record.id
    delete "#{resolve_path_for(meta)}/#{record_id}", headers: headers, as: :json
    assert_response :success
    assert_nil meta.model_class.find_by(id: record.id)
  end
end
```

`generate_show_extras` — the inline `get` call uses `record.id` directly:

```ruby
def generate_show_extras(meta)
  return unless meta.actions.include?(:show)
  show_attrs = meta.check_attributes[:show]
  return unless show_attrs&.any?

  test "show returns expected attributes" do
    record = resolve_record(:show, meta)
    record_id = meta.resource_param ? record.public_send(meta.resource_param) : record.id
    get "#{resolve_path_for(meta)}/#{record_id}", headers: admin_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    show_attrs.each { |attr| assert data.key?(attr), "Expected data.#{attr} in response" }
  end
end
```

`generate_absence_tests` — the `else` branch builds path from `record.id`:

```ruby
def generate_absence_tests(meta)
  meta.actions.each do |action|
    absent = meta.check_attributes[:"#{action}_absent"]
    next unless absent&.any?

    test "#{action} excludes hidden attributes" do
      record = resolve_record(action, meta)
      params = resolve_params(action, meta, record)
      path = case action
             when :index then resolve_path_for(meta)
             when :create then resolve_path_for(meta)
             else
               record_id = meta.resource_param ? record.public_send(meta.resource_param) : record.id
               "#{resolve_path_for(meta)}/#{record_id}"
             end

      send(http_method_for(action), path, params: params, headers: admin_headers, as: :json)
      assert_response :success

      data = action == :index ? JSON.parse(response.body).dig("data")&.first : JSON.parse(response.body).dig("data")
      absent.each { |attr| assert_not data.key?(attr), "Did not expect #{attr} in #{action} response" }
    end
  end
end
```

When `resource_param` is nil (all existing tests), all four sites fall back to `record.id` — identical to today.

**`fixture_keys:` option** — `Metadata#resolve_fixture_keys` ignores it and always loads all users from `core_users.yml`. The spec's test declarations (e.g. `fixture_keys: %i[core_admin attendee]`) have no effect on actual test generation — every user gets tested. Add the option by filtering the loaded keys:

```ruby
def resolve_fixture_keys
  fixture_file = Rails.root.join("test/fixtures/core_users.yml")
  raise "Missing test/fixtures/core_users.yml" unless fixture_file.exist?

  raw = File.read(fixture_file)
  yaml = raw.include?("<%") ? ERB.new(raw, trim_mode: "-").result(binding) : raw
  parsed = YAML.safe_load(yaml)
  @core_users_by_key = parsed.select { |_, v| v.is_a?(Hash) }
  @fixture_keys = @options[:fixture_keys] || @core_users_by_key.keys.map(&:to_sym)
end
```

When `fixture_keys:` is absent (all existing tests), behavior is identical to today.

**`parent_fixture:` option** — `Metadata#register_setup_block` defaults `parent_fixture_key` to `:one` (line 396), but `core_users.yml` has no `:one` key — it has `super_admin`, `core_admin`, `attendee`. Admin tests that trigger `parent_class_present?` must pass `parent_fixture:` (e.g. `parent_fixture: :core_admin`). The setup block runs whenever the controller declares `parent_class` — `parent_class_present?` checks the controller class, not test options. An explicit `path:` lambda does not bypass it.

### 5d. `default_serializer`

AMS auto-resolves serializers by model class name. For `Core::User`, it looks for `Core::UserSerializer` (which doesn't exist) and falls back to the base `ActiveModel::Serializer`. The `Admin::UserSerializer` defined in the spec is orphaned — never consulted.

Fix: add a `default_serializer` class_attribute to `Core::Common` and have `Core::JsonResponse#render_success` merge it into `serializer_options`:

```ruby
# In Core::Common
class_attribute :default_serializer, default: nil
```

```ruby
# In Core::JsonResponse#render_success — add before the render call:
def render_success(message = nil, data: nil, status: :ok, serializer_options: {}, pagination: nil, meta: nil, **options)
  if self.class.respond_to?(:default_serializer) && self.class.default_serializer
    serializer_options[:serializer] ||= self.class.default_serializer
  end
  # ... existing render logic
end
```

When `default_serializer` is nil (all existing controllers), behavior is unchanged. Admin controllers declare their serializer explicitly.

---

## 6. Controllers

All new files follow the domain module pattern established by Organizations/Events:

```
app/controllers/admin/
  application_controller.rb     # Base controller for admin namespace

app/controllers/admin/
  users_controller.rb           # CRUD + deactivate/reactivate
  roles_controller.rb           # CRUD
  permissions_controller.rb     # CRUD
  user_roles_controller.rb      # Nested under users (create/destroy only)

app/policies/admin/
  user_policy.rb                # User CRUD + deactivate/reactivate
  role_policy.rb                # Role CRUD
  permission_policy.rb          # Permission CRUD
  user_role_policy.rb           # Role assignment (assignable roles guard)

app/serializers/admin/
  user_serializer.rb            # Admin view of a user (includes roles)

test/fixtures/admin/
  (no additional fixtures needed — reuse core_* fixtures)

test/integration/admin/
  users_test.rb                 # resource_test for users
  roles_test.rb                 # resource_test for roles
  permissions_test.rb           # resource_test for permissions
  user_roles_test.rb            # resource_test for nested user roles
```

### `Admin::ApplicationController`

```ruby
module Admin
  class ApplicationController < Core::ApplicationController
    # Use Pundit's array-namespace pattern so all authorization resolves to Admin::*Policy.
    # Override all three methods rather than using self.policy_class — Pundit 2.5.2's
    # controller authorize(...) resolves internally via PolicyFinder, not via policy(record).
    def authorize(record, query = nil, policy_class: nil)
      super([:admin, record], query, policy_class: policy_class)
    end

    def policy_scope(scope, policy_scope_class: nil)
      super([:admin, scope], policy_scope_class: policy_scope_class)
    end

    def policy(record)
      super([:admin, record])
    end
  end
end
```

### `Admin::UsersController`

```ruby
module Admin
  class UsersController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Core::User
    self.default_serializer = Admin::UserSerializer
    auditable_model Core::User
    auditable on: %i[create update destroy deactivate reactivate]

    # Scope filter: active by default via apply_index_scope hook
    def apply_index_scope(scope)
      case params[:status]
      when "all"  then scope
      when "deactivated" then scope.deactivated
      else scope.active
      end
    end

    # Deactivate (soft delete) — revokes all sessions immediately
    def deactivate
      @obj = @clazz.find(params[:id])
      authorize @obj, :deactivate?
      ActiveRecord::Base.transaction do
        @obj.update!(deactivated_at: Time.current, deactivated_reason: params[:reason])
        Core::AuthService.call(operation: :revoke_all_user_tokens, user: @obj)
      end
      render_success(data: @obj, serializer_options: {})
    end

    # Reactivate
    def reactivate
      @obj = @clazz.find(params[:id])
      authorize @obj, :reactivate?
      @obj.update!(deactivated_at: nil, deactivated_reason: nil)
      render_success(data: @obj, serializer_options: {})
    end

    private

    def model_params
      params.require(:user).permit(:email, :phone, :password, :password_confirmation, :verified_at)
    end

    def allowed_order_columns
      %w[id email phone verified_at deactivated_at created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id email phone verified_at deactivated_at created_at updated_at] },
        show: { fields: %i[id email phone verified_at deactivated_at deactivated_reason created_at updated_at],
                include: [:roles] },
        create: { fields: %i[id email phone verified_at created_at updated_at] },
        update: { fields: %i[id email phone verified_at created_at updated_at] }
      }
    end
  end
end
```

### `Admin::RolesController`

```ruby
module Admin
  class RolesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Core::Role
    auditable_model Core::Role
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:role).permit(:code, :name, :description, :active)
    end

    def allowed_order_columns
      %w[id code name active created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id code name description active created_at updated_at] },
        show: { fields: %i[id code name description active created_at updated_at],
                include: [:permissions] },
        create: { fields: %i[id code name description active created_at updated_at] },
        update: { fields: %i[id code name description active created_at updated_at] }
      }
    end
  end
end
```

### `Admin::PermissionsController`

```ruby
module Admin
  class PermissionsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Core::Permission
    auditable_model Core::Permission
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:permission).permit(:code, :resource, :action, :namespace, :description, :active)
    end

    def allowed_order_columns
      %w[id code resource action namespace active created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id code resource action namespace description active created_at updated_at] },
        show: { fields: %i[id code resource action namespace description active created_at updated_at] },
        create: { fields: %i[id code resource action namespace description active created_at updated_at] },
        update: { fields: %i[id code resource action namespace description active created_at updated_at] }
      }
    end
  end
end
```

### `Admin::UserRolesController` (nested under users)

Uses `self.resource_param = :role_id` so Core::Common's `set_object` looks up the join record by `params[:role_id]` instead of `params[:id]`. The route `param: :role_id` (defined in Section 9) provides the correct URL segment.

```ruby
module Admin
  class UserRolesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Core::UserRole
    self.parent_class = Core::User
    self.parent_param = :user_id
    self.parent_association = :user_roles
    self.resource_param = :role_id
    auditable_model Core::UserRole
    auditable on: %i[create destroy]
    auditable_record_for :destroy, -> { Core::UserRole.find_by!(user_id: params[:user_id], role_id: params[:role_id]) }

    private

    def model_params
      params.require(:user_role).permit(:role_id)
    end

    def after_create_hook(object)
      object.update_column(:assigned_by_id, current_user.id)
    end

    def allowed_order_columns
      %w[id created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id role_id created_at] },
        create: { fields: %i[id role_id created_at] }
      }
    end
  end
end
```

The nested routing provides:
- `GET    /admin/users/:user_id/roles` → index (list roles for a user)
- `POST   /admin/users/:user_id/roles` → create (assign role, body: `{ user_role: { role_id: "..." } }`)
- `DELETE /admin/users/:user_id/roles/:role_id` → destroy (revoke role, `:role_id` = the role's UUID)

---

## 7. Policies

All policies inherit from `Core::ApplicationPolicy`, which provides the base `allowed?(action)` method:
- Returns `false` if no user
- Returns `true` if `user.super_admin?`
- Otherwise checks `user.has_permission?(permission_code)` where `permission_code = "#{resource_name}.#{action}"`

### `Admin::UserPolicy`

```ruby
module Admin
  class UserPolicy < Core::ApplicationPolicy
    # index?, show?, create?, update?, destroy? — inherited from ApplicationPolicy
    # resource_name returns "user" from record/model

    def deactivate?
      return false unless user
      return false if record == user  # no self-deactivation
      return true if user.super_admin?
      user.has_permission?("user.deactivate")
    end

    def reactivate?
      return false unless user
      return false if record == user  # no self-reactivation
      return true if user.super_admin?
      return false if record.deactivation_fraud?  # CORE_ADMIN cannot reactivate fraud accounts
      user.has_permission?("user.reactivate")
    end

    VISIBILITY = {
      show: { default: nil, admin: nil }  # No field-level gating — controller serializer_profile controls fields
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user.super_admin?
        return scope.none unless user.has_permission?("user.index")
        scope.all
      end
    end
  end
end
```

### `Admin::UserRolePolicy`

```ruby
module Admin
  class UserRolePolicy < Core::ApplicationPolicy
    # resource_name returns "user_role"
    # record is a Core::UserRole instance with role_id set from model_params

    def create?
      return false unless user
      return true if user.super_admin?

      if user.has_permission?("user_role.create")
        role = Core::Role.find_by(id: record.role_id)
        return false unless role
        return assignable_role?(role)
      end

      false
    end

    def destroy?
      return false unless user
      return true if user.super_admin?

      if user.has_permission?("user_role.destroy")
        return false unless record.role_id
        role = Core::Role.find_by(id: record.role_id)
        return false unless role
        return assignable_role?(role)
      end

      false
    end

    private

    def assignable_role?(role)
      # CORE_ADMIN can only assign or revoke USER or SUPPORT roles
      %w[USER SUPPORT].include?(role.code)
    end
  end
end
```

### `Admin::RolePolicy` and `Admin::PermissionPolicy`

Standard policies inheriting from `Core::ApplicationPolicy` with `resource_name` returning `"role"` and `"permission"` respectively. Both have `VISIBILITY = { show: { default: nil, admin: nil } }` and standard `Scope` classes.

---

## 8. Serializer

### `Admin::UserSerializer`

```ruby
module Admin
  class UserSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    attributes :id, :email, :phone, :verified_at, :deactivated_at, :deactivated_reason, :created_at, :updated_at
    has_many :roles, serializer: Core::RoleSerializer
  end
end
```

The `AttributeVisibilitySerializer` concern respects the policy's `VISIBILITY` hash. The current policy's VISIBILITY is open (`nil` for all roles) — no field-level gating. The controller's `serializer_profile` defines explicit fields for `index`, `show`, `create`, and `update`. Actions without a profile entry (`deactivate`, `reactivate`) resolve no field set — `resolved_visible_attributes` returns `nil`, and all serializer attributes are exposed. So `deactivated_reason` appears in `show`, `deactivate`, and `reactivate` responses.

---

## 9. Routes

```ruby
namespace :admin do
  resources :users, except: %i[new edit] do
    member do
      post :deactivate
      post :reactivate
    end
    resources :roles, only: %i[index create destroy], controller: "user_roles",
              as: :user_roles, param: :role_id
  end

  resources :roles, except: %i[new edit]
  resources :permissions, except: %i[new edit]
end
```

The `param: :role_id` option on the nested roles resource generates URLs with `:role_id` instead of `:id`, which Core::Common's `self.resource_param = :role_id` (declared on the controller) picks up for record lookup.

Generates:

| Method | Path | Action | URL Param |
|---|---|---|---|
| GET | /admin/users | users#index | `?status=all` to include deactivated, `?status=deactivated` for deactivated only, omit for active only |
| POST | /admin/users | users#create | — |
| GET | /admin/users/:id | users#show | `:id` = user UUID |
| PATCH | /admin/users/:id | users#update | `:id` = user UUID |
| PUT | /admin/users/:id | users#update | `:id` = user UUID |
| DELETE | /admin/users/:id | users#destroy | `:id` = user UUID |
| POST | /admin/users/:id/deactivate | users#deactivate | `:id` = user UUID |
| POST | /admin/users/:id/reactivate | users#reactivate | `:id` = user UUID |
| GET | /admin/users/:user_id/roles | user_roles#index | `:user_id` = user UUID |
| POST | /admin/users/:user_id/roles | user_roles#create | `:user_id` = user UUID |
| DELETE | /admin/users/:user_id/roles/:role_id | user_roles#destroy | `:role_id` = role UUID |
| GET | /admin/roles | roles#index | — |
| POST | /admin/roles | roles#create | — |
| GET | /admin/roles/:id | roles#show | `:id` = role UUID |
| PATCH | /admin/roles/:id | roles#update | `:id` = role UUID |
| PUT | /admin/roles/:id | roles#update | `:id` = role UUID |
| DELETE | /admin/roles/:id | roles#destroy | `:id` = role UUID |
| GET | /admin/permissions | permissions#index | — |
| POST | /admin/permissions | permissions#create | — |
| GET | /admin/permissions/:id | permissions#show | `:id` = permission UUID |
| PATCH | /admin/permissions/:id | permissions#update | `:id` = permission UUID |
| PUT | /admin/permissions/:id | permissions#update | `:id` = permission UUID |
| DELETE | /admin/permissions/:id | permissions#destroy | `:id` = permission UUID |

---

## 10. Audit Logging

All admin controllers include `Core::AuditableController` with `auditable on: %i[create update destroy]`. The `deactivate` and `reactivate` actions on `UsersController` also be audited:

```ruby
auditable on: %i[create update destroy deactivate reactivate]
```

The `AuditableController`'s `detect_model_class` auto-detects the wrong model for namespaced controllers (e.g. `Admin::UsersController` → `Admin::User`). Each admin controller calls `auditable_model` to set the correct model explicitly:

```ruby
auditable_model Core::User      # in Admin::UsersController
auditable_model Core::Role      # in Admin::RolesController
auditable_model Core::Permission  # in Admin::PermissionsController
auditable_model Core::UserRole  # in Admin::UserRolesController
```

For `UserRolesController#destroy`, `params[:role_id]` holds the role UUID (not the join record's id). The auditable controller's fallback resolution (`Priority 5: params[:id]`) won't match because there's no `:id` param. Additionally, `capture_audit_snapshot` runs *before* Core::Common's `set_object` due to Rails' before_action ordering, so `@obj` is not yet set. The `auditable_record_for` DSL provides an explicit resolver that queries by role_id directly:

```ruby
auditable_record_for :destroy, -> {
  Core::UserRole.find_by!(user_id: params[:user_id], role_id: params[:role_id])
}
```

Add this to `Admin::UserRolesController` alongside the other class-level declarations.

---

## 11. Test Fixtures

### New entries for `core_permissions.yml`

The existing file has 3 entries (`role_index`, `permission_create`, `user_index`). Add the remaining permissions:

```yaml
user_show:
  id: 019e5f6a-a001-7def-8cf6-53197a197001
  code: user.show
  resource: user
  action: show
  namespace: core
  description: View user details
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_create:
  id: 019e5f6a-a001-7def-8cf6-53197a197002
  code: user.create
  resource: user
  action: create
  namespace: core
  description: Create new users
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_update:
  id: 019e5f6a-a001-7def-8cf6-53197a197003
  code: user.update
  resource: user
  action: update
  namespace: core
  description: Update user information
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_destroy:
  id: 019e5f6a-a001-7def-8cf6-53197a197004
  code: user.destroy
  resource: user
  action: destroy
  namespace: core
  description: Delete users
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_deactivate:
  id: 019e5f6a-a001-7def-8cf6-53197a197005
  code: user.deactivate
  resource: user
  action: deactivate
  namespace: core
  description: Deactivate users
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_reactivate:
  id: 019e5f6a-a001-7def-8cf6-53197a197006
  code: user.reactivate
  resource: user
  action: reactivate
  namespace: core
  description: Reactivate deactivated users
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

role_show:
  id: 019e5f6a-a001-7def-8cf6-53197a197010
  code: role.show
  resource: role
  action: show
  namespace: core
  description: View role details
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

role_create:
  id: 019e5f6a-a001-7def-8cf6-53197a197011
  code: role.create
  resource: role
  action: create
  namespace: core
  description: Create new roles
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

role_update:
  id: 019e5f6a-a001-7def-8cf6-53197a197012
  code: role.update
  resource: role
  action: update
  namespace: core
  description: Update roles
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

role_destroy:
  id: 019e5f6a-a001-7def-8cf6-53197a197013
  code: role.destroy
  resource: role
  action: destroy
  namespace: core
  description: Delete roles
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

permission_index:
  id: 019e5f6a-a001-7def-8cf6-53197a197020
  code: permission.index
  resource: permission
  action: index
  namespace: core
  description: List all permissions
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

permission_show:
  id: 019e5f6a-a001-7def-8cf6-53197a197021
  code: permission.show
  resource: permission
  action: show
  namespace: core
  description: View permission details
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

permission_update:
  id: 019e5f6a-a001-7def-8cf6-53197a197022
  code: permission.update
  resource: permission
  action: update
  namespace: core
  description: Update permissions
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

permission_destroy:
  id: 019e5f6a-a001-7def-8cf6-53197a197023
  code: permission.destroy
  resource: permission
  action: destroy
  namespace: core
  description: Delete permissions
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_role_index:
  id: 019e5f6a-a001-7def-8cf6-53197a197030
  code: user_role.index
  resource: user_role
  action: index
  namespace: core
  description: List user role assignments
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_role_create:
  id: 019e5f6a-a001-7def-8cf6-53197a197031
  code: user_role.create
  resource: user_role
  action: create
  namespace: core
  description: Assign roles to users
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

user_role_destroy:
  id: 019e5f6a-a001-7def-8cf6-53197a197032
  code: user_role.destroy
  resource: user_role
  action: destroy
  namespace: core
  description: Revoke roles from users
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>
```

### New `core_role_permissions.yml` entries

Match the permission distribution table. CORE_ADMIN additions:

```yaml
core_admin_user_show:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197001
core_admin_user_create:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197002
core_admin_user_update:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197003
core_admin_user_deactivate:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197005
core_admin_user_reactivate:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197006
core_admin_role_show:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197010
core_admin_permission_index:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197020
core_admin_permission_show:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197021
core_admin_user_role_index:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197030
core_admin_user_role_create:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197031
core_admin_user_role_destroy:
  role_id: 019e5f69-db11-7a51-b1d9-785571600a31
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197032

support_user_index:
  role_id: 019e5f6a-9999-7def-8cf6-53197a197999
  permission_id: 019e5f69-d926-719f-b4f2-d06274c0a93d
support_user_show:
  role_id: 019e5f6a-9999-7def-8cf6-53197a197999
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197001
support_user_deactivate:
  role_id: 019e5f6a-9999-7def-8cf6-53197a197999
  permission_id: 019e5f6a-a001-7def-8cf6-53197a197005
```

### New `core_user_roles.yml` entry

Reuse `attendee` — doubling up roles (USER + SUPPORT) is the simplest approach:

```yaml
attendee_support:
  id: 019e5f6a-8888-7686-bf20-08f55514e888
  user_id: 019e5f69-dbb6-7e14-b126-c01c0c580984
  role_id: 019e5f6a-9999-7def-8cf6-53197a197999
  assigned_by_id: 019e5f69-db1c-77b6-be88-3afbf8b65410
```

The `attendee` user now has two roles: `USER` (from `attendee_assignment`) and `SUPPORT` (from `attendee_support`). The `MockUser` in `resource_test.rb` collects all roles from `core_user_roles.yml`, so policy resolution automatically includes both sets of permissions.

---

## 12. Integration Tests

### `test/integration/admin/users_test.rb`

```ruby
require "test_helper"

module Admin
  class UsersTest < ActionDispatch::IntegrationTest
    resource_test model_class: Core::User,
                  policy_class: Admin::UserPolicy,
                  path: "/admin/users",
                  fixture_keys: %i[super_admin core_admin attendee],
                  create_params: -> { { user: { email: "newuser@test.com", phone: "+251911000099", password: "Password123!" } } },
                  update_params: ->(record) { { user: { email: "updated#{record.id}@test.com" } } }

    # Additional tests for deactivate/reactivate
    test "super_admin can deactivate a user" do
      sign_in_as :super_admin
      post deactivate_admin_user_path(core_users(:attendee)), params: { reason: "inactive" }
      assert_response :ok
      assert core_users(:attendee).reload.deactivated?
    end

    test "user cannot self-deactivate" do
      sign_in_as :super_admin
      post deactivate_admin_user_path(core_users(:super_admin)), params: { reason: "test" }
      assert_response :forbidden
    end

    test "core_admin can reactivate non-fraud account" do
      user = core_users(:attendee)
      user.update!(deactivated_at: Time.current, deactivated_reason: "inactive")
      sign_in_as :core_admin
      post reactivate_admin_user_path(user)
      assert_response :ok
      assert_not user.reload.deactivated?
    end

    test "core_admin cannot reactivate fraud account" do
      user = core_users(:attendee)
      user.update!(deactivated_at: Time.current, deactivated_reason: "fraud")
      sign_in_as :core_admin
      post reactivate_admin_user_path(user)
      assert_response :forbidden
    end
  end
end
```

### `test/integration/admin/roles_test.rb`

```ruby
require "test_helper"

module Admin
  class RolesTest < ActionDispatch::IntegrationTest
    resource_test model_class: Core::Role,
                  policy_class: Admin::RolePolicy,
                  path: "/admin/roles",
                  fixture_keys: %i[core_admin attendee],
                  create_params: -> { { role: { code: "TEST_ROLE", name: "Test Role" } } },
                  update_params: ->(record) { { role: { name: "Updated Role" } } }
  end
end
```

### `test/integration/admin/permissions_test.rb`

```ruby
require "test_helper"

module Admin
  class PermissionsTest < ActionDispatch::IntegrationTest
    resource_test model_class: Core::Permission,
                  policy_class: Admin::PermissionPolicy,
                  path: "/admin/permissions",
                  fixture_keys: %i[core_admin attendee],
                  create_params: -> { { permission: { code: "test.create", resource: "test", action: "create", namespace: "core" } } },
                  update_params: ->(record) { { permission: { description: "Updated" } } }
  end
end
```

### `test/integration/admin/user_roles_test.rb`

Uses `resource_param: :role_id` so the destroy test sends `record.role_id` as the URL segment. Uses `except: %i[show update]` since those actions have no routes.

The setup block picks `core_admin`'s first user_role (the CORE_ADMIN assignment at line 7 of `core_user_roles.yml`). Core_admin cannot destroy CORE_ADMIN roles (`assignable_role?` only permits USER/SUPPORT), and attendee lacks `user_role.destroy` permission entirely. SUPER_ADMIN is the only fixture user who can destroy it — `super_admin?` bypasses the assignable-role check. Hence `fixture_keys` includes `:super_admin` to generate a permitted destroy test case.

```ruby
require "test_helper"

module Admin
  class UserRolesTest < ActionDispatch::IntegrationTest
    resource_test model_class: Core::UserRole,
                  policy_class: Admin::UserRolePolicy,
                  resource_param: :role_id,
                  path: -> { "/admin/users/#{core_users(:core_admin).id}/roles" },
                  parent_class: Core::User,
                  parent_fixture: :core_admin,
                  fixture_keys: %i[super_admin core_admin attendee],
                  except: %i[show update],
                  create_params: -> { { user_role: { role_id: core_roles(:user).id } } }
  end
end
```

---

## 13. ResourceTest Compatibility Notes

The existing `Core::ResourceTest` concern generates nested CRUD tests at class-load time. For the admin module:

1. **`Admin::UsersController#index`** applies `.active` by default (via the `apply_index_scope` hook). Pass `?status=all` to include deactivated, `?status=deactivated` for deactivated only, or omit for active only. The `resource_test` index test doesn't send query params, so it tests the default scope (active only). New records created via `create!` have `deactivated_at: nil` and pass the active scope — no special handling needed. Tests for status filter behavior are covered by the manual user integration tests below.

2. **`Admin::UserRolePolicy#create?`** checks `assignable_role?` on the role. The `resource_test` `create_params` lambda needs to provide a `role_id` that is assignable — use `core_roles(:user).id`.

3. **`resource_param: :role_id`** is passed to the `UserRolesTest` resource_test call. The `Metadata` class stores it, and `perform_request` / `generate_destroy_test` use `record.public_send(:role_id)` instead of `record.id` when constructing URL paths. The route's `param: :role_id` emits `:role_id` in the URL segment, and Core::Common's `self.resource_param = :role_id` makes `set_object` look up by `params[:role_id]`.

4. **`except: %i[show update]`** is passed to skip tests for actions that have no routes. The resource_test already supports `except:` filtering.

5. **Policy matrix tests** use `policy_matrix_test` from `Core::PolicyMatrixTest`. The `resource_test` passes `policy_class` (from `Metadata`) to it, so contract tests assert against `Admin::UserPolicy` rather than the non-existent `Core::UserPolicy`. The `Metadata#resolve_policy_class` method checks `options[:policy_class]` first before falling back to model-name inference.

6. **`parent_fixture:` option** — `Metadata#register_setup_block` defaults `parent_fixture_key` to `:one`, but `core_users.yml` has no `:one` key. Admin tests that trigger `parent_class_present?` must pass `parent_fixture:` (e.g. `parent_fixture: :core_admin`) to avoid `ActiveRecord::FixtureNotFound`. Tests with explicit `path:` lambdas still trigger the setup block if `parent_class` is declared on the controller, so the option is required regardless.

---

## 14. Updates to Existing Docs

### `docs/DOMAIN_MODULE_GENERATOR.md`

Add a section about admin domain conventions:
- Admin controllers include `Core::AuditableController` by convention
- Admin policies check `resource.action` permission codes
- Admin index scopes default to active records
- `VISIBILITY` required on all admin policies

### `.github/AGENTS.md`

Update post-generation checklist to reference admin module conventions when generating within the `Admin::` namespace.

---

## 15. Implementation Order

| Step | Files | Depends On |
|------|-------|------------|
| 1. Migration | `db/migrate/*_add_deactivated_at_to_core_users.rb` | Nothing |
| 2. Vocabulary normalization | `db/seeds.rb` (add `CORE_ADMIN` role, `permission.show` permission), `app/policies/core/application_policy.rb` (add `CORE_ADMIN` to `user_role_key`) | Nothing |
| 3. Model changes | `app/models/core/user.rb` (active scope, deactivated? helper, ransackable_attributes) | Step 1 |
| 4. Auth gate | `app/services/core/auth_service.rb` (deactivated check in authenticate_user AND refresh_access_token), `app/controllers/concerns/core/authenticatable.rb` (raise result.error in refresh_token since AuthService.call already wraps exceptions in Result.failure) | Step 3 |
| 5. Admin::ApplicationController + Core::Common improvements | `app/controllers/admin/application_controller.rb` (authorize/policy_scope/policy overrides with array namespace), `app/controllers/concerns/core/common.rb` (resource_param, default_serializer class_attributes, set_object uses resource_param for lookup), `app/controllers/concerns/core/json_response.rb` (render_success merges default_serializer) | Nothing |
| 6. ResourceTest updates | `test/support/core/resource_test.rb` (policy_class:, resource_param:, fixture_keys:, parent_fixture: options; perform_request gains meta: kwarg; generate_show_extras, generate_destroy_test, generate_absence_tests use resource_param for URL) | Step 5 |
| 7. Seed updates | `db/seeds.rb` (SUPPORT role, new permissions codes, role-permission mappings per distribution table) | Step 2 |
| 8. Fixture updates | `test/fixtures/core_roles.yml` (SUPPORT), `core_permissions.yml` (all new codes), `core_role_permissions.yml` (per distribution table), `core_user_roles.yml` (attendee_support) | Nothing |
| 9. Policies | 4 policy files under `app/policies/admin/` | Nothing |
| 10. Serializer | `app/serializers/admin/user_serializer.rb` | Nothing |
| 11. Controllers | 4 controller files under `app/controllers/admin/` | Steps 5, 9, 10 |
| 12. Routes | `config/routes.rb` (namespace :admin) | Step 11 |
| 13. Integration tests | 4 test files under `test/integration/admin/` | Steps 6, 8, 9, 11, 12 |
| 14. Auth regression tests | `test/integration/auth/deactivated_user_test.rb` (deactivated login rejects with invalid_credentials, deactivated refresh returns account_deactivated, active user unaffected) | Steps 3, 4 |
