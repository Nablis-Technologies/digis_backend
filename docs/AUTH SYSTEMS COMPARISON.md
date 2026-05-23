# Auth Systems Comparison: digis_backend vs tele_timihirt (StormAuth)

**Date**: May 21, 2026
**Purpose**: Compare the two auth implementations and identify improvements for digis_backend

---

## Executive Summary

| Aspect | digis_backend | tele_timihirt (StormAuth) | Winner |
|--------|---------------|---------------------------|--------|
| **Architecture** | Simple, flat Core namespace | Gem-based plugin system | **StormAuth** |
| **MFA Support** | None | TOTP, SMS, Email, Backup Codes | **StormAuth** |
| **OAuth/SSO** | None | Google, GitHub, Apple | **StormAuth** |
| **Rate Limiting** | None | Per-IP, per-user, per-endpoint | **StormAuth** |
| **Token Security** | Plain text refresh tokens | BCrypt-hashed refresh tokens + JTI | **StormAuth** |
| **Token Revocation** | Soft (destroy record) | Hard (revoked flag + JTI tracking) | **StormAuth** |
| **Device Tracking** | Basic (device_id, IP, UA) | Full (device_id, IP, UA, metadata JSONB) | **StormAuth** |
| **Account Locking** | Stubbed (always returns false) | Implemented with lock duration | **StormAuth** |
| **Failed Attempt Tracking** | None | Implemented | **StormAuth** |
| **RBAC** | Full (roles, permissions, user_roles) | None (just user model) | **digis_backend** |
| **Phone-First Identity** | Built-in | Email-first, phone secondary | **digis_backend** |
| **Shadow Users** | Designed (nullable password) | Not supported | **digis_backend** |
| **Simplicity** | Clean, easy to understand | Complex, enterprise-grade | **digis_backend** |
| **Extensibility** | Manual changes needed | Plugin system, strategy pattern | **StormAuth** |
| **Testing** | 13 tests (Minitest) | ~19% coverage (RSpec) | **digis_backend** |

**Verdict**: StormAuth is more feature-complete and "world-class" for enterprise use. digis_backend is simpler and better suited for the Ethiopian market (phone-first, shadow users). The best approach is to **adopt StormAuth's security patterns** while keeping digis_backend's simplicity and market-specific features.

---

## Detailed Comparison

### 1. Token Security

#### digis_backend
```ruby
# Refresh tokens stored as plain text
self.refresh_token = SecureRandom.hex(32)  # 64-char hex, stored directly
```

**Risk**: If the database is compromised, all refresh tokens are exposed and can be used immediately.

#### StormAuth
```ruby
# Refresh tokens hashed with BCrypt before storage
def hash_token
  self.token_hash = BCrypt::Password.create(raw_token) if raw_token.present?
end

def valid_token?(token)
  BCrypt::Password.new(token_hash) == token
end
```

**Benefit**: Even if the database is compromised, refresh tokens cannot be used — they're one-way hashed.

**Recommendation**: **Adopt BCrypt hashing for refresh tokens.** This is a critical security upgrade.

---

### 2. Token Revocation

#### digis_backend
```ruby
# Soft revocation — destroys the record
def revoke_refresh_token(token_value)
  Core::RefreshToken.find_by(refresh_token: token_value)&.destroy
end
```

**Risk**: No audit trail of revoked tokens. Cannot distinguish between "never existed" and "was revoked."

#### StormAuth
```ruby
# Hard revocation — sets revoked flag, keeps record
def revoke!
  update(revoked: true, revoked_at: Time.current)
end

def revoke_all_for_user(user_id)
  where(user_id: user_id, revoked: false).update_all(revoked: true, revoked_at: Time.current)
end
```

**Benefit**: Full audit trail. Can detect if a revoked token is being reused (potential attack indicator).

**Recommendation**: **Add `revoked` and `revoked_at` columns** to `core_refresh_tokens`. Soft-delete instead of destroy.

---

### 3. JTI (JWT ID) Claim

#### digis_backend
No JTI claim in JWT tokens. Access tokens are identified only by `user_id`.

**Risk**: Cannot individually revoke specific access tokens. All tokens for a user are valid until expiry.

#### StormAuth
```ruby
# Each token has a unique JTI (JWT ID)
def build_access_token_payload(user, additional_claims = {})
  {
    sub: user.id,
    jti: SecureRandom.uuid,  # Unique token identifier
    type: "access",
    iat: Time.current.to_i,
    exp: (Time.current + access_token_expiry).to_i
  }
end
```

**Benefit**: Can revoke individual tokens, detect token reuse, and build token blacklists.

**Recommendation**: **Add JTI claim to access tokens** and store them for revocation tracking.

---

### 4. Rate Limiting

#### digis_backend
No rate limiting on any auth endpoint.

**Risk**: Brute force attacks, credential stuffing, API abuse.

#### StormAuth
```ruby
# Per-endpoint rate limits
Login (IP): 5 requests / 20 seconds
Login (Phone): 5 requests / 20 seconds
Registration: 5 requests / 1 hour
OAuth Authorize: 10 requests / 1 minute
OAuth Callback: 20 requests / 5 minutes
```

**Benefit**: Prevents brute force, credential stuffing, and API abuse.

**Recommendation**: **Implement Rack::Attack or similar** for rate limiting on auth endpoints.

---

### 5. MFA (Multi-Factor Authentication)

#### digis_backend
Not implemented. Architecture designed but no code exists.

#### StormAuth
Full MFA implementation with:
- **TOTP** (Authenticator apps like Google Authenticator)
- **SMS** (One-time codes via text)
- **Email** (One-time codes via email)
- **Backup Codes** (Pre-generated recovery codes)
- **Challenge-based verification** (secure challenge tokens)
- **Strategy pattern** for adding new MFA methods

**Benefit**: Enterprise-grade security. Users can choose their preferred MFA method.

**Recommendation**: **Implement TOTP first** (most common, no external dependencies). SMS can follow for Ethiopian market.

---

### 6. OAuth/SSO

#### digis_backend
Not implemented.

#### StormAuth
Full OAuth implementation with:
- **Google** (OAuth 2.0 with OpenID Connect)
- **GitHub** (OAuth with user:email scope)
- **Apple** (Sign in with Apple)
- **Strategy pattern** for adding new providers
- **Account linking/unlinking**
- **CSRF protection** via state tokens

**Benefit**: Users can sign in with existing accounts. Reduces friction.

**Recommendation**: **Not urgent for Ethiopian market** (phone-first is more relevant). Can add later for diaspora users.

---

### 7. Account Locking

#### digis_backend
```ruby
def locked?
  false  # Always returns false — stubbed
end
```

**Risk**: No protection against brute force attacks.

#### StormAuth
```ruby
def check_account_status(user)
  if user.respond_to?(:locked?) && user.locked?
    return failure(:account_locked, locked_until: user.locked_until)
  end
  success(status: :ok)
end

def record_failed_attempt(user)
  return unless user.respond_to?(:record_failed_login_attempt)
  user.record_failed_login_attempt
end
```

**Benefit**: Accounts lock after repeated failed attempts, preventing brute force.

**Recommendation**: **Implement account locking** with configurable threshold (e.g., 5 failed attempts → 15-minute lock).

---

### 8. Failed Attempt Tracking

#### digis_backend
Not implemented.

#### StormAuth
```ruby
def record_failed_login_attempt
  # Increments failed_attempts counter
  # Locks account if threshold exceeded
  # Logs the attempt for audit
end
```

**Benefit**: Detects and prevents brute force attacks. Provides audit trail.

**Recommendation**: **Add `failed_attempts` and `locked_until` columns** to `core_users`.

---

### 9. Plugin/Extensibility System

#### digis_backend
Manual changes needed for any new auth method.

#### StormAuth
```ruby
# Plugin system with hooks
StormAuth.plugins.run_hook(:before_authenticate, context)
StormAuth.plugins.run_hook(:after_authenticate, user, context)
StormAuth.plugins.run_hook(:on_token_refresh, user, refresh_token)

# Strategy pattern for authenticators
authenticator_class = StormAuth.service_registry.find(strategy_name, category: :authenticator)
```

**Benefit**: Add new auth methods without modifying existing code. Clean separation of concerns.

**Recommendation**: **Not needed yet** — digis_backend is simpler and that's a feature, not a bug. Add when complexity demands it.

---

### 10. RBAC (Role-Based Access Control)

#### digis_backend
Full RBAC implementation:
- Roles, Permissions, UserRoles, RolePermissions
- Permission caching with automatic invalidation
- Expirable role assignments
- Assigned-by audit trail
- Super admin bypass
- Fallback Pundit policies

#### StormAuth
No RBAC. Just a user model with basic fields.

**Benefit**: digis_backend has enterprise-grade authorization that StormAuth lacks.

**Verdict**: **digis_backend wins** — this is a significant advantage.

---

### 11. Phone-First Identity

#### digis_backend
```ruby
def find_user_by_identifier(identifier)
  value = identifier.to_s.strip
  if value.include?("@")
    Core::User.find_by(email: value.downcase)
  else
    Core::User.find_by(phone: value)  # Phone is primary
  end
end
```

**Benefit**: Designed for Ethiopian market where phone numbers are the primary identity.

#### StormAuth
Email-first, phone secondary. Not optimized for phone-first markets.

**Verdict**: **digis_backend wins** — better suited for the target market.

---

### 12. Shadow Users

#### digis_backend
```ruby
# password_digest is nullable — allows phone-only users
t.string :password_digest  # No null: false constraint
```

**Benefit**: Users can buy tickets without creating a full account. A shadow user is auto-created by phone number.

#### StormAuth
Requires password for all users. No shadow user support.

**Verdict**: **digis_backend wins** — critical for frictionless ticket purchases.

---

## Recommended Improvements for digis_backend

### Priority 1: Critical Security (Implement Now)

| Improvement | Effort | Impact |
|-------------|--------|--------|
| BCrypt-hash refresh tokens | Low | High |
| Add `revoked`/`revoked_at` to refresh tokens | Low | High |
| Add JTI claim to access tokens | Low | Medium |
| Rate limiting on auth endpoints | Medium | High |

### Priority 2: Important Security (Implement Soon)

| Improvement | Effort | Impact |
|-------------|--------|--------|
| Account locking after failed attempts | Medium | High |
| Failed attempt tracking | Medium | High |
| Token revocation blacklist | Medium | Medium |

### Priority 3: Feature Enhancements (Implement Later)

| Improvement | Effort | Impact |
|-------------|--------|--------|
| TOTP MFA | High | Medium |
| SMS OTP for login (Ethiopian market) | High | High |
| OAuth for diaspora users | Medium | Low |
| Plugin system | High | Low |

---

## Implementation Plan

### Phase 1: Token Security Hardening

1. **BCrypt-hash refresh tokens**
   - Add `token_hash` column to `core_refresh_tokens`
   - Hash tokens on creation, verify on lookup
   - Keep `refresh_token` column for backward compat during migration

2. **Add JTI claim to access tokens**
   - Include `jti: SecureRandom.uuid` in JWT payload
   - Store JTI in `core_refresh_tokens` for revocation tracking

3. **Add revocation tracking**
   - Add `revoked` (boolean) and `revoked_at` (datetime) columns
   - Change `destroy` to `update(revoked: true)` on logout

### Phase 2: Rate Limiting & Account Protection

4. **Implement Rack::Attack**
   - Login: 5 requests per 20 seconds per IP
   - Registration: 5 requests per hour per IP
   - Token refresh: 10 requests per minute per IP

5. **Account locking**
   - Add `failed_attempts` (integer) and `locked_until` (datetime) columns
   - Lock after 5 failed attempts for 15 minutes
   - Reset counter on successful login

### Phase 3: MFA (Optional)

6. **TOTP MFA**
   - Add `mfa_methods` table (TOTP, SMS, Email, Backup Codes)
   - Add `mfa_challenges` table for challenge-based verification
   - Implement TOTP first (no external dependencies)

---

## Conclusion

**StormAuth is more "world-class"** in terms of security features, but **digis_backend is better suited for the Ethiopian market** with its phone-first identity and shadow user support.

The best approach is to **adopt StormAuth's security patterns** (BCrypt-hashed tokens, JTI claims, rate limiting, account locking) while **keeping digis_backend's simplicity and market-specific features** (phone-first, shadow users, RBAC).

**Key takeaway**: StormAuth's BCrypt-hashed refresh tokens are the single most important security upgrade. Implement that first.
