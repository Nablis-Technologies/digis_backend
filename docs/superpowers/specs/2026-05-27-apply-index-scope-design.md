# `apply_index_scope` Hook Design

## Goal

Eliminate the custom `index` override in `Admin::UsersController` and the policy-scope bypass it introduces, by adding a lightweight hook to `Core::Common` that any controller can use to modify the indexed scope before filtering/pagination.

## Problem

`Admin::UsersController#index` overrides `Core::Common#index` to support an `include_deactivated` toggle. The custom method duplicates Common's entire index logic and, critically, replaces the policy-scoped relation with a raw `Core::User.active` call — discarding any restrictions the policy scope applied.

## Solution

### 1. `Core::Common#index` — one-line hook

Insert after `policy_scope` and before `includes`:

```ruby
data = apply_index_scope(data)
```

Default no-op in Common (private):

```ruby
def apply_index_scope(scope)
  scope
end
```

**Contract:** The method accepts and returns an `ActiveRecord::Relation`. It is not a general-purpose data-transform hook — Common immediately continues with `.includes()`, filtering, ordering, count, and pagination on the return value. Returning a non-relation (e.g., a hash, array, or scalar) will break downstream processing.

Controllers that don't need the hook never override it — the default returns `scope` unchanged. Controllers that need custom behavior simply override.

### 2. `Admin::UsersController` — delete custom `index`, use hook

Changes:

- **Set `default_serializer`** so Common's render path picks up the right serializer:
  ```ruby
  self.default_serializer = Admin::UserSerializer
  ```

- **Delete the entire custom `index` method.**

- **Add the hook** as a private method:
  ```ruby
  def apply_index_scope(scope)
    case params[:status]
    when "all"  then scope
    when "deactivated" then scope.deactivated
    else scope.active
    end
  end
  ```

  This chains the scope filter onto the policy-scoped relation instead of replacing it.
  
  Includes and serializer are not lost — Common's `index` pulls `include:` from `serializer_profile` (already configured for `index:` with `%i[roles]`), and `default_serializer` handles the serializer class.

### 3. Enum param: `?status=active|deactivated|all`

Replace `?include_deactivated=true` with `?status=` enum:

| Param | Behavior |
|---|---|
| (omitted) | Active users only (`scope.active`) |
| `?status=active` | Active users only (explicit) |
| `?status=deactivated` | Deactivated users only (`scope.deactivated`) |
| `?status=all` | All users, no filter |

The model already exposes both `Core::User.active` and `Core::User.deactivated` scopes, so this uses the existing API rather than adding a new boolean.

**Invalid values:** Any unrecognized `status` value (e.g., `?status=archived`, `?status=`) falls through to `scope.active`. This is intentional — the default view is always active-only, and unknown values degrade safely rather than raising 400s. If stricter validation is needed later, add an allowlist before the `case`.

### 4. No other controllers affected

- `Admin::RolesController` — uses Common's index, no override. Unchanged.
- `Admin::PermissionsController` — same. Unchanged.
- `Admin::UserRolesController` — uses Common's index with `parent_class`. Unchanged.
- No other controller in the project overrides `index`.

### 5. Regression test: scope composition

The current `Admin::UserPolicy::Scope` returns `scope.all` for super_admin (no narrowing), so a live-scope test would produce the same result for both the broken and fixed code paths. To prove the composition contract, the test stubs `policy_scope` with a genuinely narrowed relation:

```ruby
test "index composes active filter with policy scope" do
  # An active user who should NOT appear — excluded by the stubbed scope below
  excluded_user = core_users(:support)

  # Stub policy_scope to return a narrowed set (simulating tenant scoping, etc.)
  narrow_scope = Core::User.where(id: core_users(:super_admin).id)
  Admin::UsersController.any_instance.stubs(:policy_scope).returns(narrow_scope)

  headers = token_headers_for(core_users(:super_admin))
  get "/admin/users", headers: headers, as: :json
  assert_response :success

  data = JSON.parse(response.body).dig("data")
  user_ids = data.map { |u| u["id"] }

  # Should only return users in BOTH the narrowed scope AND the active filter
  assert_equal [ core_users(:super_admin).id ], user_ids
end
```

This catches the exact bug: if `apply_index_scope` calls `Core::User.active` (fresh query, broken), `excluded_user` appears in the response because it's active and `Core::User.active` ignores the stubbed scope. If it chains `scope.active` (fixed), only the scoped-and-active user is returned.

Note this does not test that `Admin::UserPolicy::Scope` is correct — the policy matrix tests cover that. This test only verifies that the controller composes with whatever scope it receives.

### 6. Test updates

Update the existing `index with include_deactivated returns all users` test to use the new param:

| Test | Old | New |
|---|---|---|
| Name | `index with include_deactivated returns all users` | `index with status=all returns all users` |
| Request | `GET /admin/users?include_deactivated=true` | `GET /admin/users?status=all` |

Rename `index without include_deactivated excludes deactivated users` to `index defaults to active users` — the old name references a param being removed, and the new name describes the behavior.

Add one test for the new `status=deactivated` branch:

| Test | Request | Assertion |
|---|---|---|
| `index with status=deactivated returns only deactivated users` | `GET /admin/users?status=deactivated` | Only deactivated users in response |

```ruby
test "index with status=deactivated returns only deactivated users" do
  deactivated = core_users(:support)
  deactivated.update!(deactivated_at: Time.current, deactivated_reason: "test")

  headers = token_headers_for(core_users(:super_admin))
  get "/admin/users?status=deactivated", headers: headers, as: :json
  assert_response :success

  data = JSON.parse(response.body).dig("data")
  user_ids = data.map { |u| u["id"] }

  assert_includes user_ids, deactivated.id
  assert_not_includes user_ids, core_users(:super_admin).id
end
```

## Affected Files

| File | Change |
|---|---|
| `app/controllers/concerns/core/common.rb` | Add `apply_index_scope` call in `index`, add default no-op |
| `app/controllers/admin/users_controller.rb` | Set `default_serializer`, delete custom `index`, add `apply_index_scope` |
| `test/integration/admin/users_test.rb` | Add scope composition test; add `status=deactivated` test; update existing two tests to new naming and `?status=all` |
| `postman/Digis API_collection.json` | Update `include_deactivated` → `status` param in List Users request |
| `docs/superpowers/specs/2026-05-26-admin-rbac-module.md` | Replace `include_deactivated` references with `status` enum docs |
