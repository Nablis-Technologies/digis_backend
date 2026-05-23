# Core Authentication And RBAC

## Scope

This slice provides the minimum reusable identity and authorization foundation for the event platform.

## Authentication

### Models and Services

- `Core::User`
- `Core::RefreshToken`
- `Core::TokenService`
- `Core::AuthService`
- `Core::AuthenticationError`

### Controller Surface

- `POST /auth/signup`
- `POST /auth/login`
- `POST /auth/refresh`
- `POST /auth/logout`
- `GET /auth/me`

### Important Behavior

- users can authenticate with either email or phone
- passwords use `has_secure_password`
- refresh tokens are persisted
- access tokens are JWTs
- auth responses are serialized through AMS (`Core::UserAuthSerializer`)
- refresh token renewal validates device ID when both the request and stored token have one
- refresh token renewal does not hard-bind to IP address

That last point is an intentional change from the old engine because field operations and mobile devices make strict IP binding too brittle.

## Authorization

### Core Types

- `Core::Role`
- `Core::Permission`
- `Core::UserRole`
- `Core::RolePermission`
- `Core::ApplicationPolicy`
- `Core::Authorizable`
- `Core::PermissionRegistry`
- `Core::AttributeVisibilitySerializer`

### Per-Role Attribute Visibility

Policies can restrict which response attributes each role sees via `visible_attributes_for(record:, action:)`. This is the role-based layer of a two-layer system:

| Layer | Location | Purpose |
|-------|----------|---------|
| Per-action | `controller.serializer_profile[action][:fields]` | What actions expose |
| Per-role | `policy.visible_attributes_for` | What roles can see |

See `docs/AUTHORIZABLE_MODULE_DOCUMENTATION.md` for full usage.

### Current Model

This is a global RBAC foundation, not the final event-platform authorization model.

It is meant to support:

- platform admins
- internal support and operations
- shared permission vocabulary
- future domain permission registration

It is not yet the full answer for:

- organization-scoped permissions
- event-scoped staffing
- temporary scanner crews
- venue- or gate-specific authority

Those layers should be added above this base, not forced into global roles.

## Default Role Creation

Signup creates or reuses a default `USER` role and assigns it to the new user.

This keeps the auth slice usable before a full permission seeding story is introduced.
