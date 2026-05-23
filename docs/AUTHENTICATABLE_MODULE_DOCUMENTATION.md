# Authenticatable Module Documentation

## Overview

The `Core::Authenticatable` module provides JWT Bearer token authentication for API controllers. It extracts and validates access tokens from the `Authorization` header, resolves the authenticated user, and provides helper methods for token-based access control.

## Table of Contents

- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Authentication Flow](#authentication-flow)
- [Helper Methods](#helper-methods)
- [Error Responses](#error-responses)
- [Token Format](#token-format)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Installation

Include the Authenticatable module in your controller:

```ruby
module Core
  class SecuredController < Core::ApplicationController
    include Core::Authenticatable

    before_action :authenticate_user!

    def index
      # current_user is available
      render json: { user: current_user }
    end
  end
end
```

## Basic Usage

### Require Authentication

```ruby
before_action :authenticate_user!
```

This ensures all actions in the controller require a valid JWT token.

### Optional Authentication

```ruby
before_action :authenticate_user!, only: [:create, :update, :destroy]
```

Only specific actions require authentication.

### Conditional Authentication

```ruby
before_action :authenticate_user!, unless: :public_action?

private

def public_action?
  action_name == "index" || action_name == "show"
end
```

## Authentication Flow

1. Client sends request with `Authorization: Bearer <token>` header
2. `authenticate_user!` extracts the token from the header
3. Token is validated (signature, expiration, format)
4. User is resolved from the token's `sub` claim
5. `current_user` is set for the request lifecycle
6. If any step fails, appropriate error response is returned

## Helper Methods

### `authenticate_user!`

Requires authentication. Returns 401 if no token or invalid token.

```ruby
before_action :authenticate_user!
```

### `current_user`

Returns the authenticated user. `nil` if not authenticated.

```ruby
def show
  if current_user
    render json: current_user
  else
    render json: { error: "Not authenticated" }, status: :unauthorized
  end
end
```

### `user_signed_in?`

Returns `true` if a user is authenticated.

```ruby
def index
  if user_signed_in?
    render json: { message: "Welcome, #{current_user.email}" }
  else
    render json: { message: "Welcome, guest" }
  end
end
```

### `authenticate_user`

Same as `authenticate_user!` but doesn't raise an error. Returns `nil` if not authenticated.

```ruby
before_action :authenticate_user
```

## Error Responses

### Missing Authorization Header

```json
{
  "success": false,
  "error": "Authorization header missing"
}
```

**HTTP Status:** 401 Unauthorized

### Invalid Token Format

```json
{
  "success": false,
  "error": "Invalid token format. Use: Bearer <token>"
}
```

**HTTP Status:** 401 Unauthorized

### Expired Token

```json
{
  "success": false,
  "error": "Token expired"
}
```

**HTTP Status:** 401 Unauthorized

### Invalid Token

```json
{
  "success": false,
  "error": "Invalid token"
}
```

**HTTP Status:** 401 Unauthorized

### User Not Found

```json
{
  "success": false,
  "error": "User not found"
}
```

**HTTP Status:** 404 Not Found

## Token Format

### Authorization Header

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### JWT Payload

```json
{
  "sub": "user-uuid",
  "iat": 1716000000,
  "exp": 1716003600,
  "type": "access"
}
```

| Claim | Description |
|-------|-------------|
| `sub` | User UUID |
| `iat` | Issued at timestamp |
| `exp` | Expiration timestamp |
| `type` | Token type ("access") |

## Best Practices

1. **Always use `before_action :authenticate_user!`** — Protect all secured endpoints
2. **Use `current_user` for authorization checks** — Combine with `Core::Authorizable` for RBAC
3. **Handle token expiration gracefully** — Implement refresh token flow
4. **Never expose tokens in URLs** — Always use `Authorization` header
5. **Use HTTPS** — Tokens are sensitive credentials

## Troubleshooting

### "Authorization header missing" Error

Ensure the client sends the `Authorization` header:

```bash
curl -H "Authorization: Bearer <token>" https://api.example.com/endpoint
```

### "Invalid token format" Error

The header must be exactly `Bearer <token>` (case-sensitive):

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### "Token expired" Error

Use the refresh token endpoint to get a new access token:

```bash
curl -X POST https://api.example.com/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refresh_token": "<refresh_token>"}'
```

### "User not found" Error

The user associated with the token no longer exists. Re-authenticate.
