---
created: 2026-05-21T07:57:03+00:00
branch: add-platform-foundation
trigger: compact
restored: true
restored_at: 2026-05-21T12:00:00+00:00
topic: add-platform-foundation
---

# Handoff: add-platform-foundation

## Goal

Architect and build an event ticketing platform as a **modular monolith** Rails application. `Core` is one module providing shared infrastructure (auth, RBAC, concerns, base services). Domain features live in their own modules (`Events`, `Ticketing`, `Orders`, `Organizations`, `Messaging`, `BoxOffice`, `ShortUrls`).

## Current State

- **Critical code issues fixed**: `password_digest` nullable, `temp_password` removed, `has_secure_password validations: false`
- **27 tests pass**, 0 RuboCop offenses
- **Shadow user creation works**: `Core::User.create!(phone: '+251911999999')` → `password_digest: nil`
- **Documentation complete**: 10 module documentation files in `docs/`
- **Agent files created**: `.github/AGENTS.md`, `.github/copilot-instructions.md`, 8 agent files
- **Postman collection**: `postman/Digis API_collection.json` with auth endpoints
- **Seed data**: `db/seeds.rb` with idempotent RBAC seeds

## Key Decisions

- **Modular monolith**: `Core` is one module, not the entire application
- **Module namespaces**: `Events::*`, `Ticketing::*`, `Orders::*`, etc.
- **Base classes**: Each module has its own base classes inheriting from `Core::*`
- **No circular dependencies**: Modules only depend on `Core` + specific other modules
- **Zero-debt rule**: Edit original migrations, delete old code completely
- **Phone-first identity**: OTP verification, shadow accounts, password optional
- **Offline scanning**: Manifest-based sync for venues with poor network

## Modified Files

- db/migrate/20260516000200_create_core_users.rb (removed temp_password, made password_digest nullable)
- db/schema.rb (updated core_users table)
- app/models/concerns/core/user_authenticatable.rb (added validations: false)
- test/fixtures/core_users.yml (removed temp_password references)
- .github/AGENTS.md (updated for modular monolith)
- .github/copilot-instructions.md (updated for modular monolith)
- docs/EVENT PLATFORM ARCHITECTURE REVIEW AND REDESIGN.md (added modular monolith note)
- docs/*_DOCUMENTATION.md (10 documentation files)

## Failed Approaches

(none)

## Files to Read

- `docs/superpowers/specs/2026-05-19-short-url-system-cloudflare-workers.md` (spec)
- `docs/superpowers/specs/2026-05-19-short-url-system-design.md` (spec)
- `docs/superpowers/plans/2026-05-17-phone-first-auth-and-organizations.md` (plan)
- `docs/EVENT PLATFORM ARCHITECTURE REVIEW AND REDESIGN.md` (architecture spec)
- `docs/PLATFORM COMPREHENSIVE CODE REVIEW.md` (code review findings)

## Next Steps

1. Implement module base classes (`Events::ApplicationRecord`, `Events::ApplicationController`, etc.)
2. Implement Organization and Membership models (`Organizations` module)
3. Implement Event and Venue models (`Events` module)
4. Implement TicketType and Ticket models (`Ticketing` module)
5. Implement Order and Payment models (`Orders` module)
6. Implement Platform Configuration System and `FeeCalculator`
7. Implement Short URL system (Cloudflare Worker + Rails sync)

## Open Questions

- Should modules be in separate directories (e.g., `app/modules/events/`) or flat (`app/models/events/`)?
- How to handle cross-module transactions (e.g., Order creation touches Ticketing, Orders, Core)?
