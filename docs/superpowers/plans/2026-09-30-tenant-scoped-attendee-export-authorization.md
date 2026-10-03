# Tenant-Scoped Attendee Export Authorization Implementation Plan

> **For agentic workers:** Execute the tasks in order in the current feature branch. Use TDD; do not stage or commit.

**Goal:** Let authorized tenant event managers request standard attendee exports without assigning global `ORGANIZER`, while preserving stronger PII field gates.

**Architecture:** Keep event manageability as the mandatory tenant boundary. Represent standard-field authorization as the `:event_manager` capability, derive contact authorization from active owner/admin membership of the primary or active co-organizer organization (or an explicit platform permission), and keep dietary/accessibility permissions explicit. Do not change role assignment; remove the obsolete global `ORGANIZER` standard-request grant.

**Tech Stack:** Rails 8.1, Pundit-style policy, Minitest, PostgreSQL-backed fixtures.

---

### Task 1: Prove tenant-scoped field permissions in policy tests

**Files:**
- Modify: `test/policies/ticketing/attendee_export_policy_test.rb`
- Modify: `test/services/ticketing/exports/field_registry_test.rb`

- [x] Add assertions that a primary owner/admin and active co-organizer owner can request standard fields without `attendee_export.request`.
- [x] Add assertions that an active event manager can request standard fields without global export permissions, but cannot request contact fields until `attendee_export.contact` is explicitly granted.
- [x] Change contact-field coverage so active primary/co-organizer owners/admins can export contact fields without global role promotion.
- [x] Keep dietary/accessibility tests requiring their dedicated permissions; keep unrelated-event, staff, scanner, inactive manager, and requester-recheck denial coverage.
- [x] Assert `FieldRegistry` labels standard fields with the `:event_manager` capability instead of a global request permission.
- [x] Run `bin/rails test test/policies/ticketing/attendee_export_policy_test.rb`; confirmed the new behavior failed before policy implementation.

### Task 2: Implement the narrow policy mapping

**Files:**
- Modify: `app/policies/ticketing/attendee_export_policy.rb`
- Modify: `app/services/ticketing/exports/field_registry.rb`
- Modify: `db/seeds/base.rb`
- Modify: `test/fixtures/core_role_permissions.yml`

- [x] Represent standard fields as the `:event_manager` capability and require event manageability before accepting that capability.
- [x] Resolve `attendee_export.contact` from an explicit platform permission or an active owner/admin membership in the event's primary organization or an active `co_organizer` organization.
- [x] Continue checking all other field permissions with `user.has_permission?`, preserving explicit dietary/accessibility gates and expired tombstone behavior.
- [x] Remove `attendee_export.request` from the default `ORGANIZER` permission seed and fixture; retain `attendee_export.contact` as an explicit platform-level override.
- [x] Run the policy suite; it passes.

### Task 3: Verify the authenticated API flow and regression suite

**Files:**
- Modify: `test/integration/ticketing/attendee_exports_test.rb`
- Modify: `test/services/ticketing/exports/field_registry_test.rb`
- Modify: `docs/superpowers/specs/2026-08-09-private-attendee-exports-design.md`
- Create: `docs/superpowers/specs/2026-09-30-tenant-scoped-attendee-export-authorization-design.md`

- [x] Add an integration test using a default-`USER` authenticated account with an active organization admin membership, reauthentication proof, and `Idempotency-Key`; assert standard export creation returns `201` without assigning `ORGANIZER` or export permissions.
- [x] Update the older design's authorization section to reference the tenant-scoped decision in `docs/superpowers/specs/2026-09-30-tenant-scoped-attendee-export-authorization-design.md`.
- [x] Run the focused field-registry, policy, and integration suites, including `N_PLUS_ONE=1`; 52 tests and 237 assertions pass.
- [x] Run RuboCop on all changed Ruby files with caching disabled; no offenses. Run `git diff --check` on the implementation files.
- [x] Review the final diff and verify no global role assignment, organization-create/promotion flow, route, database, Postman, or frontend files changed.
