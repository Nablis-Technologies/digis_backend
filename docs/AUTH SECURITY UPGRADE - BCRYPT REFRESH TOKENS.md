# Auth Security Upgrade: BCrypt-Hashed Refresh Tokens

**Date**: May 21, 2026
**Status**: ✅ Complete

## Problem

Refresh tokens were stored as plain text in the database. If the database was compromised, all active refresh tokens could be used immediately by an attacker.

## Solution

Implemented dual-hash storage for refresh tokens:

| Column | Purpose | Algorithm |
|--------|---------|-----------|
| `token_fingerprint` | Fast lookup | SHA256 |
| `token_hash` | Secure verification | BCrypt (cost factor 10) |

### How It Works

1. **Generation**: Raw token → SHA256 fingerprint (lookup) + BCrypt hash (verification)
2. **Storage**: Only hashes stored in DB, raw token returned to user once
3. **Verification**: Find by fingerprint → verify against BCrypt hash
4. **Revocation**: Soft-delete (`revoked: true`) instead of destroy

### Security Benefit

If the database is compromised:
- SHA256 fingerprint cannot be reversed to get raw token
- BCrypt hash cannot be reversed to get raw token
- Attacker cannot use stored values to authenticate

## Files Changed

| File | Change |
|------|--------|
| `db/migrate/20260516000300_create_core_refresh_tokens.rb` | Added `token_fingerprint`, `token_hash`, `revoked`, `revoked_at` columns |
| `db/schema.rb` | Updated to match new migration |
| `app/models/core/refresh_token.rb` | Added BCrypt hashing, fingerprint lookup, `find_valid`, `revoke!` |
| `app/services/core/auth_service.rb` | Updated to use `find_valid`, `revoke!`, return `raw_token` |
| `app/controllers/core/auth_controller.rb` | Fixed to use raw token string directly |
| `test/fixtures/core_refresh_tokens.yml` | Updated with fingerprint and BCrypt hash |
| `test/models/core/refresh_token_test.rb` | Added 6 new tests for hashing, verification, revocation |
| `test/integration/core/auth_test.rb` | Updated to use raw token and verify revocation |

## Test Results

- **33 tests pass**, 0 failures, 0 errors
- **0 RuboCop offenses**
- Manual verification confirms: fingerprint lookup works, BCrypt verification works, revocation works

## Next Steps

1. Add JTI claim to access tokens (enables individual token revocation)
2. Implement rate limiting on auth endpoints
3. Add account locking after failed attempts
