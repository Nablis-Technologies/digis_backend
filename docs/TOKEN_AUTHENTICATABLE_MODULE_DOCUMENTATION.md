# TokenAuthenticatable Module Documentation

## Overview

The `Core::TokenAuthenticatable` module provides token generation helpers for API authentication. It supports generating, validating, and revoking JWT access and refresh tokens, with secure token rotation for refresh tokens.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Token Generation](#token-generation)
- [Token Validation](#token-validation)
- [Token Rotation](#token-rotation)
- [Token Revocation](#token-revocation)
- [Token Claims](#token-claims)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Basic Usage

Include the TokenAuthenticatable module in your service or controller:

```ruby
module Core
  class AuthService
    include Core::TokenAuthenticatable

    def login(user)
      tokens = generate_tokens(user)
      { access_token: tokens[:access], refresh_token: tokens[:refresh] }
    end
  end
end
```

## Token Generation

### Generate Access Token

```ruby
access_token = generate_access_token(user)
```

**Payload:**

```json
{
  "sub": "user-uuid",
  "iat": 1716000000,
  "exp": 1716003600,
  "type": "access"
}
```

### Generate Refresh Token

```ruby
refresh_token = generate_refresh_token(user)
```

**Payload:**

```json
{
  "sub": "user-uuid",
  "jti": "unique-token-id",
  "iat": 1716000000,
  "exp": 1716086400,
  "type": "refresh"
}
```

### Generate Both Tokens

```ruby
tokens = generate_tokens(user)
# => { access: "eyJ...", refresh: "eyJ..." }
```

## Token Validation

### Validate Access Token

```ruby
payload = validate_access_token(token)
# => { "sub" => "user-uuid", "type" => "access", ... }
```

### Validate Refresh Token

```ruby
payload = validate_refresh_token(token)
# => { "sub" => "user-uuid", "jti" => "unique-token-id", "type" => "refresh", ... }
```

### Validate Any Token

```ruby
payload = validate_token(token)
# => { "sub" => "user-uuid", "type" => "access", ... }
```

## Token Rotation

### Rotate Refresh Token

```ruby
new_tokens = rotate_refresh_token(old_refresh_token)
# => { access: "new-access-token", refresh: "new-refresh-token" }
```

**Rotation Flow:**

1. Validate the old refresh token
2. Mark the old refresh token as revoked
3. Generate new access and refresh tokens
4. Return the new tokens

### Race Condition Prevention

The rotation uses atomic database operations to prevent race conditions:

```ruby
# Atomic token rotation
def rotate_refresh_token(token)
  payload = validate_refresh_token(token)
  revoke_token(payload["jti"])
  user = Core::User.find(payload["sub"])
  generate_tokens(user)
end
```

## Token Revocation

### Revoke Single Token

```ruby
revoke_token(jti)
```

### Revoke All User Tokens

```ruby
revoke_all_user_tokens(user)
```

### Check Token Revocation

```ruby
token_revoked?(jti)
# => true or false
```

## Token Claims

### Standard Claims

| Claim | Description |
|-------|-------------|
| `sub` | User UUID |
| `iat` | Issued at timestamp |
| `exp` | Expiration timestamp |
| `jti` | Unique token ID (refresh tokens only) |
| `type` | Token type ("access" or "refresh") |

### Custom Claims

Add custom claims to tokens:

```ruby
def generate_access_token(user, custom_claims = {})
  payload = {
    sub: user.id,
    type: "access",
    role: user.primary_role
  }.merge(custom_claims)

  JWT.encode(payload, Rails.application.credentials.jwt_secret, "HS256")
end
```

## Best Practices

1. **Use short-lived access tokens** — 15 minutes is typical
2. **Use long-lived refresh tokens** — 7 days is typical
3. **Always rotate refresh tokens** — Prevents token replay attacks
4. **Store refresh tokens securely** — Use httpOnly cookies or secure storage
5. **Revoke tokens on logout** — Prevents token reuse after logout

## Troubleshooting

### "Token expired" Error

The token has passed its expiration time. Use the refresh token to get a new access token:

```ruby
new_tokens = rotate_refresh_token(refresh_token)
```

### "Token revoked" Error

The token has been revoked (e.g., during rotation or logout). Re-authenticate:

```ruby
# Re-authenticate
tokens = generate_tokens(user)
```

### "Invalid token" Error

The token signature is invalid or the token format is incorrect. Ensure the token is properly formatted:

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### "Race condition during rotation" Error

The refresh token was already rotated. This can happen if multiple requests use the same refresh token simultaneously. Re-authenticate:

```ruby
# Re-authenticate
tokens = generate_tokens(user)
```
