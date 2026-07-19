# Authentication & RBAC Authorization — Complete Reference

> This document is the single source of truth for how authentication, role-based access control, and policy authorization work in the Digis backend. It covers every model, service, concern, policy, and data flow involved.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Database Schema](#3-database-schema)
4. [Authentication Layer](#4-authentication-layer)
   - 4.1 [Models](#41-models)
   - 4.2 [Services](#42-services)
   - 4.3 [Controller Concerns](#43-controller-concerns)
   - 4.4 [Auth Endpoints](#44-auth-endpoints)
   - 4.5 [Login Flow](#45-login-flow)
   - 4.6 [Signup Flow](#46-signup-flow)
   - 4.7 [Token Refresh Flow](#47-token-refresh-flow)
   - 4.8 [Logout Flow](#48-logout-flow)
   - 4.9 [Token Internals](#49-token-internals)
   - 4.10 [Device Binding](#410-device-binding)
   - 4.11 [Deactivation Guard](#411-deactivation-guard)
5. [Authorization Layer (RBAC)](#5-authorization-layer-rbac)
   - 5.1 [Data Model — Four-Table RBAC Graph](#51-data-model--four-table-rbac-graph)
   - 5.2 [Seeded Roles & Hierarchy](#52-seeded-roles--hierarchy)
   - 5.3 [Seeded Permissions Catalog](#53-seeded-permissions-catalog)
   - 5.4 [Role → Permission Mapping](#54-role--permission-mapping)
   - 5.5 [Permission Resolution on User](#55-permission-resolution-on-user)
   - 5.6 [SUPER_ADMIN Bypass](#56-super_admin-bypass)
   - 5.7 [Permission Caching](#57-permission-caching)
6. [Policy Layer (Pundit)](#6-policy-layer-pundit)
   - 6.1 [Core::ApplicationPolicy](#61-coreapplicationpolicy)
   - 6.2 [Permission Code Convention](#62-permission-code-convention)
   - 6.3 [Policy Scope](#63-policy-scope)
   - 6.4 [Per-Role Attribute Visibility (VISIBILITY)](#64-per-role-attribute-visibility-visibility)
   - 6.5 [Core::Authorizable Concern](#65-coreauthorizable-concern)
   - 6.6 [Fallback Policy Mechanism](#66-fallback-policy-mechanism)
   - 6.7 [Admin Namespace Policies](#67-admin-namespace-policies)
   - 6.8 [Admin Policy Inventory](#68-admin-policy-inventory)
   - 6.9 [Domain Policies (Events, Organizations)](#69-domain-policies-events-organizations)
7. [Organization-Scoped Authorization](#7-organization-scoped-authorization)
   - 7.1 [Membership Role Hierarchy](#71-membership-role-hierarchy)
   - 7.2 [Strict Weight Rule](#72-strict-weight-rule)
   - 7.3 [Owner Uniqueness Constraint](#73-owner-uniqueness-constraint)
8. [Request Lifecycle — Full Trace](#8-request-lifecycle--full-trace)
9. [Serialization](#9-serialization)
10. [Error Handling](#10-error-handling)
11. [Controller Integration Patterns](#11-controller-integration-patterns)
    - 11.1 [Securing a New Controller](#111-securing-a-new-controller)
    - 11.2 [Skipping Authorization](#112-skipping-authorization)
    - 11.3 [Custom Policy Targets](#113-custom-policy-targets)
    - 11.4 [Admin Controllers](#114-admin-controllers)
12. [Testing RBAC](#12-testing-rbac)
13. [File Inventory](#13-file-inventory)

---

## 1. System Overview

The Digis backend implements a **two-layer security system**:

| Layer | Question It Answers | Technology |
|-------|---------------------|------------|
| **Authentication** | Who are you? | JWT (HS256) + BCrypt refresh tokens |
| **Authorization** | What can you do? | Pundit policies + database permission catalog |

Both layers are wired into every controller through `Core::ApplicationController`, which includes both concerns and runs them as `before_action` hooks:

```ruby
# app/controllers/core/application_controller.rb
module Core
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable   # authentication
    include Core::Authorizable      # authorization (Pundit)

    before_action :authenticate_user
    before_action :authorize_action!
  end
end
```

Every API request must pass both gates before the controller action executes.

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Client Request                             │
│              Authorization: Bearer <JWT access token>                │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   Core::Authenticatable                              │
│  1. Extract Bearer token from Authorization header                  │
│  2. TokenService.decode(token, verify_revocation: true)             │
│  3. Find user by payload["user_id"]                                 │
│  4. Set @current_user                                               │
│  → Fail: raise AuthenticationError → 401                            │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   Core::Authorizable                                 │
│  1. Resolve policy target (controller-defined or model-based)       │
│  2. Find policy class (Pundit::PolicyFinder or fallback)            │
│  3. Call policy.<action>? (e.g., policy.index?)                     │
│     ├─ SUPER_ADMIN? → always true                                   │
│     └─ user.has_permission?("resource.action")                      │
│        └─ JOIN user_roles → roles → role_permissions → permissions  │
│  → Fail: raise Pundit::NotAuthorizedError → 403                     │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Controller Action                                │
│  - Executes business logic                                          │
│  - after_action :verify_authorized ensures authorize was called     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Database Schema

All tables use **UUID primary keys** (via `pgcrypto` or `uuidv7()`).

### core_users

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK, `uuidv7()` |
| `email` | string(150) | unique, nullable |
| `phone` | string(30) | unique, nullable |
| `password_digest` | string | BCrypt hash via `has_secure_password` |
| `verified_at` | datetime | Account verification timestamp |
| `deactivated_at` | datetime | Soft-delete/deactivation timestamp |
| `deactivated_reason` | string | e.g., `"fraud"` |
| `created_at` / `updated_at` | datetime | Timestamps |

### core_roles

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK, `uuidv7()` |
| `code` | string(50) | unique, auto-uppercased |
| `name` | string(100) | Display name |
| `description` | string | Optional description |
| `active` | boolean | default: true |

### core_permissions

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK, `uuidv7()` |
| `code` | string(100) | unique, auto-generated as `"resource.action"` |
| `resource` | string(50) | e.g., `"user"`, `"event"`, `"ticket"` |
| `action` | string(50) | e.g., `"index"`, `"create"`, `"destroy"` |
| `namespace` | string(50) | default: `"core"`, also `"admin"` |
| `description` | string | Optional description |
| `active` | boolean | default: true |

Unique constraint: `(resource, action, namespace)`.

### core_user_roles

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK, `uuidv7()` |
| `user_id` | uuid | FK → core_users |
| `role_id` | uuid | FK → core_roles |
| `assigned_by_id` | uuid | FK → core_users (who assigned this role) |
| `expires_at` | datetime | Optional expiration for temporary access |

Unique constraint: `(user_id, role_id)`.

### core_role_permissions

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK, `uuidv7()` |
| `role_id` | uuid | FK → core_roles |
| `permission_id` | uuid | FK → core_permissions |

Unique constraint: `(role_id, permission_id)`.

### core_refresh_tokens

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK, `uuidv7()` |
| `user_id` | uuid | FK → core_users |
| `jti` | string | unique, UUID for token identification |
| `token_hash` | string | BCrypt hash of raw token |
| `token_fingerprint` | string | unique, SHA256 hash for lookup |
| `device_id` | string | Optional device binding |
| `ip_address` | string | IP at creation time |
| `user_agent` | string | User-Agent at creation time |
| `revoked` | boolean | default: false |
| `revoked_at` | datetime | When revoked |
| `expires_at` | datetime | 30 days from creation |

---

## 4. Authentication Layer

### 4.1 Models

**`Core::User`** (`app/models/core/user.rb`)
- Includes `Core::UserAuthenticatable` (password auth, token generation)
- Includes `Core::AuditableModel` (audit trail)
- Associations: `has_many :roles` (through `user_roles`), `has_many :refresh_tokens`, `has_many :memberships`, `has_many :organizations`
- Scopes: `.active` (where `deactivated_at` IS NULL), `.deactivated`
- Identity: either email or phone must be present (validated), both normalized (stripped, email lowercased)

**`Core::RefreshToken`** (`app/models/core/refresh_token.rb`)
- Stores BCrypt-hashed refresh tokens with SHA256 fingerprint for index-friendly lookups
- `raw_token` is a transient `attr_accessor` — only available at creation time, never persisted in plaintext
- Scopes: `.active` (not revoked, not expired), `.revoked`, `.for_device(device_id)`
- `find_valid(token)`: looks up by fingerprint, then verifies BCrypt hash
- `generate(user, request)`: creates a new token with device/IP/user-agent tracking

### 4.2 Services

**`Core::AuthService`** (`app/services/core/auth_service.rb`)
- Command-pattern service: `AuthService.call(operation:, **params)` → `Result.success/failure`
- Inherits from `Core::BaseService` which provides `Result` value object and `self.call(...)` shorthand
- All `Core::Error` exceptions are caught in `call` and wrapped as `Result.failure(error)`

Supported operations:

| Operation | Method | Description |
|-----------|--------|-------------|
| `:authenticate_user` | `authenticate_user(identifier, password)` | Find user by email/phone, verify password, check deactivation |
| `:generate_auth_tokens` | `generate_auth_tokens(user, request)` | Create refresh token + issue JWT access token |
| `:refresh_access_token` | `refresh_access_token(refresh_token_value, request)` | Rotate tokens: revoke old, issue new pair |
| `:revoke_refresh_token` | `revoke_refresh_token(token_value)` | Revoke a single refresh token |
| `:revoke_all_user_tokens` | `revoke_all_user_tokens(user)` | Revoke all active refresh tokens for a user |

**`Core::TokenService`** (`app/services/core/token_service.rb`)
- Issues and decodes HS256 JWTs
- Access token payload: `{ user_id, jti, identifier, type: "access", roles: [...] }`
- The `roles` array in the JWT payload is populated at issuance time from `user.active_role_codes`
- Decoding supports revocation verification: checks the token's `jti` against revoked refresh tokens
- Secret key resolution order: `CORE_JWT_SECRET_KEY` → `JWT_SECRET_KEY` → test key (test env) → `Rails.application.secret_key_base`
- Token lifetimes: access = 15 minutes, refresh = 30 days

### 4.3 Controller Concerns

**`Core::Authenticatable`** (`app/controllers/concerns/core/authenticatable.rb`)

| Method | Visibility | Purpose |
|--------|-----------|---------|
| `current_user` | public | Lazily resolves user from Bearer token (memoized per request) |
| `authenticate_user` | public | Raises `AuthenticationError` if no `current_user` — used as `before_action` |
| `sign_in(user, request)` | public | Generates auth tokens and sets `@current_user` |
| `sign_out` | public | Revokes refresh token from params, clears `@current_user` |
| `refresh_token!` | public | Delegates to `AuthService.refresh_access_token`, re-raises errors |
| `authenticate_from_token` | private | Extracts token from header → decodes → finds user |
| `extract_access_token_from_header` | private | Parses `Authorization: Bearer <token>` |
| `extract_refresh_token_from_params` | private | Reads `params[:refresh_token]` |
| `handle_authentication_error` | private | Renders JSON error response with status code and error code |

**`Core::UserAuthenticatable`** (`app/models/concerns/core/user_authenticatable.rb`)

Model-level concern mixed into `Core::User`:

| Method | Purpose |
|--------|---------|
| `authenticate_with_password(password)` | Delegates to `has_secure_password`'s `authenticate` |
| `generate_auth_tokens(request)` | Delegates to `AuthService.call(operation: :generate_auth_tokens)` |
| `valid_for_authentication?` | Returns `true` if `active?` AND NOT `locked?` |
| `active?` | Always `true` (override point for future use) |
| `locked?` | Always `false` (override point for future use) |
| `revoke_all_tokens` | Delegates to `AuthService.call(operation: :revoke_all_user_tokens)` |
| `track_device(request)` | Returns hash of `{ user_agent, ip_address, device_id }` |

### 4.4 Auth Endpoints

Defined in `config/routes.rb`:

```ruby
scope module: :core do
  post "auth/login",    to: "auth#login"
  post "auth/signup",   to: "auth#signup"
  post "auth/refresh",  to: "auth#refresh"
  post "auth/logout",   to: "auth#logout"
  get  "auth/me",       to: "auth#me"
end
```

| Endpoint | Auth Required | Authorization Required | Description |
|----------|:---:|:---:|-------------|
| `POST /auth/login` | No | No | Authenticate with email/phone + password |
| `POST /auth/signup` | No | No | Create new user, auto-assign `USER` role |
| `POST /auth/refresh` | No | No | Rotate refresh token, get new access token |
| `POST /auth/logout` | Yes | No | Revoke refresh token |
| `GET /auth/me` | Yes | No | Return current user with roles and permissions |

### 4.5 Login Flow

```
POST /auth/login  { identifier: "admin@digis.et", password: "password123" }
        │
        ▼
AuthController#login
        │
        ├─ AuthService.call(operation: :authenticate_user, identifier:, password:)
        │       │
        │       ├─ find_user_by_identifier("admin@digis.et")
        │       │   → contains "@" → Core::User.find_by(email: "admin@digis.et")
        │       │
        │       ├─ user.authenticate("password123")
        │       │   → BCrypt comparison via has_secure_password
        │       │
        │       ├─ user.deactivated? → return nil if true
        │       │
        │       └─ return user (or nil)
        │
        ├─ user.valid_for_authentication?  (active? && !locked?)
        │
        ├─ sign_in(user, request)
        │       │
        │       ├─ user.generate_auth_tokens(request)
        │       │       │
        │       │       ├─ RefreshToken.generate(user, request)
        │       │       │   → creates DB record with BCrypt hash + SHA256 fingerprint
        │       │       │
        │       │       └─ TokenService.issue(access_token_payload(user, jti:))
        │       │           → JWT with { user_id, jti, identifier, type: "access", roles: [...] }
        │       │
        │       └─ @current_user = user
        │
        └─ render_success(user:, access_token:, refresh_token:)
           → serialized via Core::UserAuthSerializer
```

### 4.6 Signup Flow

```
POST /auth/signup  { user: { email:, phone:, password:, password_confirmation: } }
        │
        ▼
AuthController#signup
        │
        ├─ Core::User.new(user_params)
        │
        ├─ transaction:
        │       ├─ user.save!
        │       └─ assign_default_role(user)
        │           → Core::Role.find_or_create_by!(code: "USER")
        │           → Core::UserRole.find_or_create_by!(user:, role:)
        │
        └─ render_success(user:) with status: :created
```

Every new user automatically receives the `USER` role, which has minimal permissions (event and ticket viewing only).

### 4.7 Token Refresh Flow

```
POST /auth/refresh  { refresh_token: "abc123..." }
        │
        ▼
AuthController#refresh → refresh_token!
        │
        ├─ RefreshToken.find_valid("abc123...")
        │       ├─ fingerprint = SHA256("abc123...")
        │       ├─ find by fingerprint WHERE active (not revoked, not expired)
        │       └─ verify BCrypt hash matches raw token
        │
        ├─ Check user.deactivated? → raise "account_deactivated" if true
        │
        ├─ validate_device!(refresh_token, request)
        │       → if stored token has device_id, request must match
        │
        ├─ transaction:
        │       ├─ create new RefreshToken (with old device_id carried over)
        │       ├─ revoke old token (revoked: true, revoked_at: now)
        │       └─ issue new JWT access token
        │
        └─ render_success(access_token:, refresh_token:, user:)
```

### 4.8 Logout Flow

```
POST /auth/logout  { refresh_token: "abc123..." }
        │
        ▼
AuthController#logout → sign_out
        │
        ├─ AuthService.call(operation: :revoke_refresh_token, token_value:)
        │       → RefreshToken.find_valid(token_value)&.revoke!
        │
        ├─ @current_user = nil
        │
        └─ render_success(:"auth.success.logout")
```

### 4.9 Token Internals

**Access Token (JWT):**
```json
{
  "user_id": "uuid-of-user",
  "jti": "uuid-matching-refresh-token-jti",
  "identifier": "admin@digis.et",
  "type": "access",
  "roles": ["SUPER_ADMIN"],
  "exp": 1718200000,
  "iat": 1718199100
}
```

- Signed with HS256
- 15-minute expiry
- `jti` links to the refresh token that was issued alongside it — enables revocation checking

**Refresh Token (Database-backed):**
- Raw value: `SecureRandom.hex(32)` — 64-character hex string
- Storage: BCrypt hash in `token_hash`, SHA256 in `token_fingerprint`
- Lookup uses fingerprint (indexed), verification uses BCrypt
- 30-day expiry
- Rotated on every use (old token revoked atomically)

**Revocation check flow:**
1. `TokenService.decode(token, verify_revocation: true)`
2. Decode JWT, extract `jti` from payload
3. `RefreshToken.exists?(jti: jti, revoked: true)` → if true, raise `"token_revoked"`

### 4.10 Device Binding

When a refresh token is created with a `device_id` (from `request.params[:device_id]`), subsequent refresh requests **must** present the same `device_id`. This prevents stolen refresh tokens from being used on different devices.

Validation logic in `AuthService.validate_device!`:
- If stored token has `device_id` AND request doesn't provide matching one → raise `"invalid_device"`
- If stored token has no `device_id` → no device check performed (allows flexible adoption)

### 4.11 Deactivation Guard

Deactivated users are blocked at two authentication entry points:

| Entry Point | Behavior | Error Code |
|-------------|----------|------------|
| **Login** | `authenticate_user` returns `nil` after password check succeeds | `invalid_credentials` (401) |
| **Token refresh** | `refresh_access_token` raises after finding valid token | `account_deactivated` (401) |

This means:
- A deactivated user cannot log in again
- A deactivated user's existing access tokens continue working until they expire (15 min)
- A deactivated user cannot refresh their access token once it expires

---

## 5. Authorization Layer (RBAC)

### 5.1 Data Model — Four-Table RBAC Graph

```
Core::User
    │
    │ has_many :user_roles
    ▼
Core::UserRole ──── belongs_to ──── Core::Role
    │                                   │
    │ (active scope:                    │ has_many :role_permissions
    │  expires_at nil                   ▼
    │  OR expires_at > now)       Core::RolePermission ──── belongs_to ──── Core::Permission
```

**Relationships:**
- User ↔ Role: many-to-many through `UserRole` (a user can have multiple roles)
- Role ↔ Permission: many-to-many through `RolePermission` (a role can have multiple permissions)
- `UserRole` carries metadata: `assigned_by_id` (who granted the role) and `expires_at` (temporary access)

### 5.2 Seeded Roles & Hierarchy

Seeded in `db/seeds.rb`:

| Role Code | Name | Description | Hierarchy Level |
|-----------|------|-------------|-----------------|
| `SUPER_ADMIN` | Super Admin | Full platform access — manages everything | Highest |
| `ADMIN` | Admin | Organization admin — manages events, tickets, team | High |
| `CORE_ADMIN` | Core Admin | Platform operational — manages users, roles, permissions, orgs | High |
| `SUPPORT` | Support | View users, deactivate accounts, view audit logs | Medium |
| `ORGANIZER` | Organizer | Creates and manages events, tickets, orders | Medium |
| `USER` | User | Default end-user — browse and purchase tickets | Lowest |

### 5.3 Seeded Permissions Catalog

All permissions are in the `core` namespace unless noted:

| Resource | Actions | Total |
|----------|---------|-------|
| `user` | index, show, create, update, destroy, deactivate, reactivate | 7 |
| `role` | index, show, create, update, destroy | 5 |
| `permission` | index, show, create, update, destroy | 5 |
| `user_role` | index, create, destroy | 3 |
| `event` | index, show, create, update, destroy, publish | 6 |
| `ticket` | index, show, create, update, destroy, scan | 6 |
| `order` | index, show, create, update, refund | 5 |
| `organization` | index, show, create, update, destroy, manage_memberships, transfer_ownership | 7 |
| `venue` | index, show, create, update, destroy | 5 |
| `artist` | index, show, create, update, destroy | 5 |
| `audit_log` | index, show | 2 |
| `review` | index, show, approve, reject | 4 |
| `verifications` (admin ns) | approve, reject, request_modification | 3 |

**Total: 63 permissions**

Permission codes follow the convention `"resource.action"`, e.g.:
- `"user.index"` — list users
- `"event.publish"` — publish events
- `"organization.transfer_ownership"` — transfer org ownership

### 5.4 Role → Permission Mapping

As seeded:

| Role | Permissions Granted | Exclusions |
|------|-------------------|------------|
| `SUPER_ADMIN` | **ALL** active permissions | None — full access |
| `ADMIN` | All except `permission.destroy` | Cannot delete permissions |
| `CORE_ADMIN` | user/role/permission/user_role/audit_log/venue/artist CRUD + org index/show/create/update/manage_memberships | No `user.destroy`, no `permission.destroy`, no `organization.destroy`, no `organization.transfer_ownership` |
| `SUPPORT` | user index/show/deactivate, role index/show, audit_log index/show, organization index/show | Read-only + deactivate |
| `ORGANIZER` | event, ticket, order, organization, review (all actions in those resources) | No user/role/permission management |
| `USER` | event index/show, ticket index/show | Read-only browsing |

### 5.5 Permission Resolution on User

`Core::User` provides these query methods:

```ruby
# Single permission check
user.has_permission?("event.create")
# → SUPER_ADMIN? → true immediately
# → Otherwise: query DB through active user_roles → active roles → active permissions

# Bulk checks
user.has_any_permission?("event.create", "event.update")  # any of these
user.has_all_permissions?("event.create", "event.update") # all of these

# Role checks
user.has_role?("ADMIN")         # checks active_role_codes
user.super_admin?               # shorthand for has_role?("SUPER_ADMIN")

# Get all active data
user.active_role_codes          # => ["SUPER_ADMIN"]
user.active_permissions         # => ["user.index", "user.show", "role.create", ...]
```

**SQL query behind `has_permission?`:**
```sql
SELECT DISTINCT core_permissions.code
FROM core_permissions
  INNER JOIN core_role_permissions ON core_role_permissions.permission_id = core_permissions.id
  INNER JOIN core_roles ON core_roles.id = core_role_permissions.role_id
  INNER JOIN core_user_roles ON core_user_roles.role_id = core_roles.id
WHERE core_user_roles.user_id = ?
  AND core_user_roles.expires_at IS NULL OR core_user_roles.expires_at > NOW()
  AND core_roles.active = true
  AND core_permissions.active = true
```

### 5.6 SUPER_ADMIN Bypass

The `SUPER_ADMIN` role has a special bypass at every level:

| Location | Bypass |
|----------|--------|
| `User#has_permission?` | `return true if super_admin?` — skips DB query entirely |
| `ApplicationPolicy#allowed?` | `return true if user.super_admin?` — skips permission check |
| `ApplicationPolicy::Scope#resolve` | `return scope.all if user.super_admin?` — no record filtering |

### 5.7 Permission Caching

Both `active_permissions` and `active_role_codes` are **memoized** on the user instance:

```ruby
def active_permissions
  @active_permissions ||= Core::Permission.joins(...).pluck(:code)
end
```

The cache is automatically invalidated when a `UserRole` record changes:

```ruby
# app/models/core/user_role.rb
after_commit :clear_user_cache!

def clear_user_cache!
  user&.clear_permission_cache!  # sets @active_permissions = nil, @active_role_codes = nil
end
```

This means within a single request, the permission query runs at most once regardless of how many `has_permission?` calls are made.

---

## 6. Policy Layer (Pundit)

### 6.1 Core::ApplicationPolicy

**File:** `app/policies/core/application_policy.rb`

The base policy class all other policies inherit from:

```ruby
module Core
  class ApplicationPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    # Standard CRUD action checks — all delegate to allowed?
    def index?;    allowed?(:index);    end
    def show?;     allowed?(:show);     end
    def create?;   allowed?(:create);   end
    def update?;   allowed?(:update);   end
    def destroy?;  allowed?(:destroy);  end

    # Attribute visibility for serialization
    def visible_attributes_for(record:, action:); ... end
    def included_associations_for(action:, default_includes:); ... end
    def association_fields_for(action:); ... end

    # Role tier detection
    def user_role_key
      return :admin if user has SUPER_ADMIN, ADMIN, or CORE_ADMIN role
      :default
    end

    private

    def allowed?(action)
      return false unless user
      return true if user.super_admin?
      user.has_permission?(permission_code(action))
    end

    def permission_code(action)
      "#{resource_name}.#{action}"   # e.g., "user.index"
    end

    def resource_name
      target = record.is_a?(Class) ? record : record.class
      target.model_name.element      # e.g., Core::User → "user"
    end
  end
end
```

### 6.2 Permission Code Convention

Permission codes are automatically derived from the record's model name and the action:

| Record Class | Action | Permission Code Checked |
|-------------|--------|------------------------|
| `Core::User` | `:index` | `"user.index"` |
| `Core::User` | `:deactivate` | `"user.deactivate"` |
| `Core::Role` | `:create` | `"role.create"` |
| `Events::Category` | `:show` | `"category.show"` |
| `Organizations::Organization` | `:update` | `"organization.update"` |

The resource name comes from `model_name.element`, which strips the namespace and underscorifies.

### 6.3 Policy Scope

`ApplicationPolicy::Scope` controls which records a user can see in index actions:

```ruby
class Scope
  def resolve
    return scope.none unless user                    # unauthenticated → nothing
    return scope.all if user.super_admin?            # SUPER_ADMIN → everything
    return scope.none unless user.has_permission?(index_permission_code)
    scope.all                                        # has permission → everything
  end

  private

  def index_permission_code
    "#{resource_name}.index"
  end
end
```

Individual policies override `Scope` for custom behavior. For example, `Admin::UserPolicy::Scope` also grants access if the user has `"user.show"` permission:

```ruby
class Admin::UserPolicy::Scope < Core::ApplicationPolicy::Scope
  def resolve
    return scope.none unless user
    return scope.all if user.super_admin?
    return scope.all if user.has_permission?("user.index") || user.has_permission?("user.show")
    scope.none
  end
end
```

### 6.4 Per-Role Attribute Visibility (VISIBILITY)

Policies can define a `VISIBILITY` constant to control which response attributes each role tier sees. This is a **two-layer system**:

| Layer | Location | Purpose |
|-------|----------|---------|
| Per-action | `controller.serializer_profile[action][:fields]` | What the action exposes |
| Per-role | `policy.visible_attributes_for(record:, action:)` | What the role can see |

The final serialized attributes are the **intersection** of both layers.

Example from `Admin::UserPolicy`:

```ruby
VISIBILITY = {
  index: {
    admin:   { fields: %i[id email phone verified_at deactivated_at deactivated_reason], include: %i[roles] },
    default: { fields: %i[id email phone verified_at deactivated_at],                   include: %i[roles] }
  },
  show: {
    admin:   { fields: %i[id email phone verified_at deactivated_at deactivated_reason created_at updated_at], include: %i[roles] },
    default: { fields: %i[id email phone verified_at deactivated_at created_at updated_at],                   include: %i[roles] }
  }
}.freeze
```

- **admin tier** (SUPER_ADMIN, ADMIN, CORE_ADMIN): sees `deactivated_reason`
- **default tier** (everyone else): does NOT see `deactivated_reason`

The `include` key controls which associations are eager-loaded and serialized.

The `association_fields` key can further restrict which fields of included associations are exposed.

### 6.5 Core::Authorizable Concern

**File:** `app/controllers/concerns/core/authorizable.rb`

This is the controller-side integration point:

```ruby
module Core
  module Authorizable
    extend ActiveSupport::Concern
    include ::Pundit::Authorization

    included do
      class_attribute :_skip_authorize_actions, default: Set.new
      after_action :verify_authorized          # ensures every action authorized
      rescue_from ::Pundit::NotAuthorizedError, with: :handle_not_authorized
    end
  end
end
```

**Key methods:**

| Method | Purpose |
|--------|---------|
| `authorize_action!` | Called as `before_action`. Resolves policy target, calls `authorize(target)` |
| `pundit_user` | Returns `current_user` — Pundit passes this to policy constructors |
| `authorize(record, query)` | Overridden to provide fallback to `Core::ApplicationPolicy` when no specific policy exists |
| `policy_scope(scope)` | Overridden to provide fallback scope from `Core::ApplicationPolicy::Scope` |
| `skip_authorization` (class method) | Skips both `before_action` and `after_action` for specified actions |
| `skip_authorization_for_action?` | Checks if current action is in the skip set |
| `handle_not_authorized` | Renders 403 with code `"not_authorized"` |

### 6.6 Fallback Policy Mechanism

When `authorize(record)` is called and Pundit cannot find a specific policy class (raises `Pundit::NotDefinedError`), the `Authorizable` concern falls back:

```ruby
def authorize(record, query = nil, policy_class: nil)
  super                              # try Pundit's normal resolution
rescue ::Pundit::NotDefinedError
  fallback_policy = Core::ApplicationPolicy.new(pundit_user, record)
  effective_query = (query || "#{action_name}?").to_s

  unless fallback_policy.respond_to?(effective_query, true) &&
         fallback_policy.public_send(effective_query)
    raise ::Pundit::NotAuthorizedError, ...
  end

  record
end
```

This means **any model** can be authorized without a dedicated policy class — it just uses the conventional `"resource.action"` permission code against `Core::ApplicationPolicy`.

The same fallback exists for `policy_scope`:

```ruby
def policy_scope(scope, policy_scope_class: nil)
  super
rescue ::Pundit::NotDefinedError
  Core::ApplicationPolicy::Scope.new(pundit_user, scope).resolve
end
```

### 6.7 Admin Namespace Policies

**File:** `app/controllers/admin/application_controller.rb`

`Admin::ApplicationController` overrides all three Pundit methods to resolve `Admin::*Policy` classes:

```ruby
module Admin
  class ApplicationController < Core::ApplicationController
    def authorize(record, query = nil, policy_class: nil)
      admin_policy = resolve_admin_policy(record)
      effective_query = (query || "#{action_name}?").to_s
      unless admin_policy.public_send(effective_query)
        raise ::Pundit::NotAuthorizedError, ...
      end
      @pundit_authorized = true
      record
    end

    def policy_scope(scope)
      admin_policy = resolve_admin_policy(scope)
      admin_policy.class::Scope.new(pundit_user, scope).resolve
    rescue NameError
      Core::ApplicationPolicy::Scope.new(pundit_user, scope).resolve
    end

    def policy(record)
      resolve_admin_policy(record)
    rescue NameError
      super
    end

    private

    def resolve_admin_policy(record)
      klass = policy_target_class(record)
      simple_name = klass.name.demodulize
      "Admin::#{simple_name}Policy".constantize.new(pundit_user, record)
    end
  end
end
```

**Resolution pattern:** For a `Core::User` record, it resolves `Admin::UserPolicy`. The demodulized class name is used, so the same policy works regardless of the model's namespace.

### 6.8 Admin Policy Inventory

All policies in `app/policies/admin/`:

| Policy File | Authorizes | Custom Actions | Notes |
|-------------|-----------|----------------|-------|
| `user_policy.rb` | `Core::User` | `deactivate?`, `reactivate?` | `reactivate?` blocks non-super-admins from reactivating fraud-deactivated users |
| `role_policy.rb` | `Core::Role` | — | Standard CRUD |
| `permission_policy.rb` | `Core::Permission` | — | Standard CRUD |
| `user_role_policy.rb` | `Core::UserRole` | — | `create?`/`destroy?` guard: non-super-admins can only assign/revoke `USER` and `SUPPORT` roles |
| `organization_policy.rb` | `Organizations::Organization` | `transfer_ownership?` | Transfer requires specific permission |
| `membership_policy.rb` | `Organizations::Membership` | — | Admin-side membership management |
| `verification_policy.rb` | Verification actions | `approve?`, `reject?`, `request_modification?` | Org verification workflow |
| `category_policy.rb` | `Events::Category` | — | Standard CRUD |
| `venue_policy.rb` | `Events::Venue` | — | Standard CRUD |
| `artist_policy.rb` | `Events::Artist` | — | Standard CRUD |

**Notable guard — `Admin::UserRolePolicy`:**

```ruby
def create?
  return false unless allowed?(:create)
  return false unless user.super_admin? || assignable_role?
  true
end

def destroy?
  return false unless allowed?(:destroy)
  return false unless user.super_admin? || assignable_role?
  true
end

private

def assignable_role?
  role_code = record.role&.code
  return true unless role_code
  %w[USER SUPPORT].include?(role_code)  # non-super-admins can only assign these
end
```

This prevents privilege escalation — a `CORE_ADMIN` cannot assign themselves `SUPER_ADMIN`.

**Notable guard — `Admin::UserPolicy#reactivate?`:**

```ruby
def reactivate?
  return false if record.deactivation_fraud? && !user.super_admin?
  allowed?(:reactivate)
end
```

Only `SUPER_ADMIN` can reactivate users who were deactivated for fraud.

### 6.9 Domain Policies (Events, Organizations)

**Events policies** (`app/policies/events/`):

| Policy | Custom Behavior |
|--------|----------------|
| `category_policy.rb` | Standard CRUD + `VISIBILITY` for per-role field filtering |
| `venue_policy.rb` | Standard CRUD + `VISIBILITY` |
| `artist_policy.rb` | Standard CRUD + `VISIBILITY` |

**Organization policies** (`app/policies/organizations/`):

| Policy | Custom Behavior |
|--------|----------------|
| `organization_policy.rb` | Checks membership role: `owner` and `admin` can update, `owner` can manage memberships |
| `membership_policy.rb` | **Strict role weight hierarchy** — see Section 7 |
| `verification_policy.rb` | Controls verification submission/resubmission by org owners |

---

## 7. Organization-Scoped Authorization

Separate from the global RBAC system, organizations use a **membership-based role system**.

### 7.1 Membership Role Hierarchy

| Membership Role | Weight | Description |
|-----------------|--------|-------------|
| `owner` | 3 | Organization owner — full control, can transfer ownership |
| `admin` | 2 | Organization admin — manages events, team |
| `staff` | 1 | Staff member — limited operations |

Defined in `Core::User::ROLE_WEIGHT`:
```ruby
ROLE_WEIGHT = { "owner" => 3, "admin" => 2, "staff" => 1 }.freeze
```

### 7.2 Strict Weight Rule

From `Organizations::MembershipPolicy`:

> An actor can only mutate a target membership if their role weight is **strictly greater** than the target's.

```ruby
def can_manage?
  return false unless current_membership
  actor_weight  = ROLE_WEIGHT[current_membership.role.to_sym]
  target_weight = ROLE_WEIGHT[@membership.role.to_sym]
  actor_weight > target_weight  # strictly greater — admin can't touch admin
end
```

This means:
- `owner` can manage `admin` and `staff`
- `admin` can manage `staff` only
- `admin` **cannot** manage another `admin`
- `staff` cannot manage anyone

### 7.3 Owner Uniqueness Constraint

The database enforces that each organization has exactly one owner:

```sql
-- schema.rb
CREATE UNIQUE INDEX idx_one_owner_per_org
  ON organizations_memberships (organization_id)
  WHERE role = 'owner';
```

User-level helpers for organization roles on `Core::User`:

```ruby
user.organizer?                          # has any active membership
user.member_of?(organization)            # active membership in this org
user.has_role_in?(organization, :owner)  # specific role in org
user.most_privileged_role_in(org)        # highest-weight role in org
```

---

## 8. Request Lifecycle — Full Trace

```
HTTP Request
│
├── [1] Core::Authenticatable: authenticate_user (before_action)
│   ├── Extract "Authorization: Bearer <token>" header
│   ├── TokenService.decode(token, verify_revocation: true)
│   │   ├── JWT.decode with HS256 + secret key
│   │   ├── Check expiration → raise "token_expired" if expired
│   │   ├── Check signature → raise "invalid_token" if bad sig
│   │   └── Check jti revocation → raise "token_revoked" if revoked
│   ├── Verify payload["type"] == "access"
│   ├── Core::User.find_by(id: payload["user_id"])
│   ├── Set @current_user
│   └── FAIL → raise AuthenticationError → render 401
│
├── [2] Core::Authorizable: authorize_action! (before_action)
│   ├── Resolve policy target
│   │   ├── Controller defines policy_target_for_authorization? → use it
│   │   └── Otherwise → nil (skip for now, verified in after_action)
│   ├── Find policy class
│   │   ├── Resource-specific policy exists? → use it
│   │   ├── Admin namespace? → resolve Admin::*Policy
│   │   └── Fallback → Core::ApplicationPolicy
│   ├── Call policy.<action>? (e.g., policy.index?)
│   │   ├── user nil? → false → 403
│   │   ├── user.super_admin? → true (bypass)
│   │   └── user.has_permission?("resource.action")
│   │       └── DB: user_roles → roles → role_permissions → permissions
│   │           (all filtered by active=true and non-expired)
│   └── FAIL → raise Pundit::NotAuthorizedError → render 403
│
├── [3] Controller action executes
│   ├── Business logic
│   ├── policy_scope(Model) for index queries
│   └── Serialization with VISIBILITY filtering
│
└── [4] Core::Authorizable: verify_authorized (after_action)
    └── Ensures authorize() was called during the request
        → FAIL if skipped without explicit skip_authorization
```

---

## 9. Serialization

**`Core::UserAuthSerializer`** (`app/serializers/core/user_auth_serializer.rb`)

Used for all auth endpoint responses:

```ruby
module Core
  class UserAuthSerializer < ActiveModel::Serializer
    attributes :id, :email, :phone, :verified_at, :created_at, :updated_at, :permissions

    has_many :roles, serializer: Core::RoleSerializer

    def permissions
      object.active_permissions.to_a  # computed permission codes
    end
  end
end
```

**Per-role visibility** is applied at the controller level through `policy.visible_attributes_for(record:, action:)`. The controller intersects the policy's allowed fields with its own serializer profile to determine the final JSON output.

---

## 10. Error Handling

**`Core::AuthenticationError`** (`app/errors/core/authentication_error.rb`):

```ruby
class AuthenticationError < Core::Error
  attr_reader :status_code, :code

  def initialize(message = "Authentication failed", status_code: 401, code: "authentication_failed")
    super(message)
    @status_code = status_code
    @code = code
  end
end
```

### Error Code Reference

| Error Code | HTTP Status | Trigger |
|------------|:-----------:|---------|
| `authentication_required` | 401 | No Bearer token in request to protected endpoint |
| `invalid_credentials` | 401 | Wrong email/phone or password during login |
| `token_expired` | 401 | JWT access token past its 15-minute expiry |
| `invalid_token` | 401 | Malformed JWT, bad signature, or invalid refresh token |
| `token_revoked` | 401 | Access token's jti matches a revoked refresh token |
| `account_deactivated` | 401 | User account has `deactivated_at` set |
| `invalid_device` | 401 | Refresh request device_id doesn't match stored device_id |
| `authentication_failed` | 401 | Generic/default authentication failure |
| `not_authorized` | 403 | Pundit policy check returned false |
| `signup_failed` | 422/500 | User creation failed (validation or server error) |

All errors are rendered as JSON:
```json
{
  "success": false,
  "error": "Error message",
  "code": "error_code"
}
```

---

## 11. Controller Integration Patterns

### 11.1 Securing a New Controller

```ruby
module Events
  class TicketsController < Core::ApplicationController
    # authenticate_user and authorize_action! are inherited from Core::ApplicationController

    def index
      @tickets = policy_scope(Events::Ticket)
      render_success(data: @tickets)
    end

    def create
      @ticket = Events::Ticket.new(ticket_params)
      authorize @ticket          # checks TicketPolicy#create? → "ticket.create"
      @ticket.save!
      render_success(data: @ticket, status: :created)
    end
  end
end
```

### 11.2 Skipping Authorization

```ruby
class PublicController < Core::ApplicationController
  # Skip auth entirely for health checks
  skip_before_action :authenticate_user, only: [:health]
  skip_authorization only: [:health]

  # Skip authorization but keep authentication
  skip_authorization only: [:dashboard]
end
```

### 11.3 Custom Policy Targets

When the default model-based policy target doesn't work, define `policy_target_for_authorization`:

```ruby
class CustomController < Core::ApplicationController
  def show
    @report = generate_report
    authorize @report, :show?   # explicit authorize with specific query
    render_success(data: @report)
  end

  private

  def policy_target_for_authorization
    @report || Report
  end
end
```

### 11.4 Admin Controllers

Admin controllers inherit from `Admin::ApplicationController` and automatically resolve `Admin::*Policy`:

```ruby
module Admin
  class UsersController < Admin::ApplicationController
    # authorize resolves to Admin::UserPolicy
    # policy_scope resolves to Admin::UserPolicy::Scope

    def deactivate
      @user = Core::User.find(params[:id])
      authorize @user, :deactivate?    # calls Admin::UserPolicy#deactivate?
      @user.update!(deactivated_at: Time.current)
      render_success(data: @user)
    end
  end
end
```

---

## 12. Testing RBAC

**Test helpers** (`test/support/core/auth_test_helpers.rb`):

```ruby
module Core
  module AuthTestHelpers
    extend ActiveSupport::Concern

    included do
      setup :setup_auth_tokens
    end

    private

    def setup_auth_tokens
      @auth_admin_token = issue_token(:super_admin)  # fixture key
      @auth_user_token  = issue_token(:attendee)      # fixture key
    end

    def admin_headers
      { "Authorization" => "Bearer #{@auth_admin_token}" }
    end

    def user_headers
      { "Authorization" => "Bearer #{@auth_user_token}" }
    end

    def issue_token(fixture_key)
      Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(fixture_key))
      )
    end
  end
end
```

**Fixtures** provide baseline users, roles, permissions, and role assignments. Integration tests drive auth endpoints and verify permission-gated behavior.

---

## 13. File Inventory

### Models
| File | Purpose |
|------|---------|
| `app/models/core/user.rb` | User identity, role associations, permission queries |
| `app/models/core/role.rb` | Role with code, name, active flag |
| `app/models/core/permission.rb` | Permission with resource/action/namespace/code |
| `app/models/core/user_role.rb` | User↔Role join with expiration and audit trail |
| `app/models/core/role_permission.rb` | Role↔Permission join |
| `app/models/core/refresh_token.rb` | Persisted refresh tokens with BCrypt + SHA256 |
| `app/models/concerns/core/user_authenticatable.rb` | Password auth, token generation, device tracking |

### Services
| File | Purpose |
|------|---------|
| `app/services/core/auth_service.rb` | Command-pattern auth operations |
| `app/services/core/token_service.rb` | JWT issuance, decoding, revocation checks |
| `app/services/core/base_service.rb` | Result object, `self.call(...)` pattern |

### Controller Concerns
| File | Purpose |
|------|---------|
| `app/controllers/concerns/core/authenticatable.rb` | Token extraction, current_user, sign_in/out, refresh |
| `app/controllers/concerns/core/authorizable.rb` | Pundit integration, fallback policy, skip_authorization |

### Controllers
| File | Purpose |
|------|---------|
| `app/controllers/application_controller.rb` | Root — `ActionController::API` |
| `app/controllers/core/application_controller.rb` | Base with auth + authorization hooks |
| `app/controllers/core/auth_controller.rb` | Login, signup, logout, me, refresh |
| `app/controllers/admin/application_controller.rb` | Admin namespace policy resolution |

### Policies
| File | Purpose |
|------|---------|
| `app/policies/core/application_policy.rb` | Base policy — `allowed?`, VISIBILITY, Scope |
| `app/policies/admin/user_policy.rb` | User CRUD + deactivate/reactivate + VISIBILITY |
| `app/policies/admin/role_policy.rb` | Role CRUD + VISIBILITY |
| `app/policies/admin/permission_policy.rb` | Permission CRUD + VISIBILITY |
| `app/policies/admin/user_role_policy.rb` | Role assignment with assignable_role guard |
| `app/policies/admin/organization_policy.rb` | Org management + transfer_ownership |
| `app/policies/admin/membership_policy.rb` | Admin-side membership management |
| `app/policies/admin/verification_policy.rb` | Org verification approve/reject/modify |
| `app/policies/admin/category_policy.rb` | Category CRUD |
| `app/policies/admin/venue_policy.rb` | Venue CRUD |
| `app/policies/admin/artist_policy.rb` | Artist CRUD |
| `app/policies/events/category_policy.rb` | Public category access + VISIBILITY |
| `app/policies/events/venue_policy.rb` | Public venue access + VISIBILITY |
| `app/policies/events/artist_policy.rb` | Public artist access + VISIBILITY |
| `app/policies/organizations/organization_policy.rb` | Org member access control |
| `app/policies/organizations/membership_policy.rb` | Strict weight-based membership management |
| `app/policies/organizations/verification_policy.rb` | Org verification submission |

### Errors
| File | Purpose |
|------|---------|
| `app/errors/core/error.rb` | Base error class |
| `app/errors/core/authentication_error.rb` | Auth error with status_code and code |

### Serializers
| File | Purpose |
|------|---------|
| `app/serializers/core/user_auth_serializer.rb` | Auth response user serialization with permissions |

### Database
| File | Purpose |
|------|---------|
| `db/schema.rb` | Full schema definition |
| `db/seeds.rb` | Idempotent seed: users, roles, permissions, assignments |
| `db/migrate/*` | Migration files for all core tables |

### Tests
| File | Purpose |
|------|---------|
| `test/support/core/auth_test_helpers.rb` | Token issuance helpers for integration tests |
| `test/fixtures/core/*` | Fixture data for users, roles, permissions, assignments |
