---
created: 2026-05-26T22:00:00Z
branch: add-platform-foundation
trigger: manual
restored: false
topic: admin-rbac-spec
---

# Handoff: Admin RBAC spec — Pundit namespace refinement

## Goal
Update the Admin RBAC module spec to use Pundit's official array-namespace pattern (`authorize([:admin, record])`) instead of the `policy_class` + `authorize_record`/`scope_records` approach that was technically incorrect — Pundit's `authorize/record)` resolves via `PolicyFinder`, not through the controller's `policy(record)` helper.

## Current State
- **Done:** Full spec review cycle completed — 13 high/medium issues identified and fixed across 3 rounds
- **Done:** Pundit approach replaced in the spec — three one-line overrides on `Admin::ApplicationController` (`authorize`, `policy_scope`, `policy`) passing `[:admin, record]` array
- **Done:** `self.policy_class` removed from all 4 admin controllers (Users, Roles, Permissions, UserRoles)
- **Done:** `authorize_record`/`scope_records` removed from UsersController — now uses `authorize`/`policy_scope` directly
- **Done:** `policy_for_data` subsection removed from spec — no longer needed
- **Done:** Implementation order table updated — step 5 merges Admin::ApplicationController + Core::Common, step 9 removed, deps renumbered
- **Done:** Spec verified clean — 0 instances of `authorize_record`, `scope_records`, `policy_for_data`, `self.policy_class` (only 1 comment reference)

## Key Decisions
- **Pundit array namespace over policy_class** — `authorize([:admin, record])` is Pundit's documented API for namespace resolution; `policy_class` class_attribute + `authorize_record`/`scope_records` helpers added indirection that Pundit's internals don't use
- **Override all three methods** — Pundit 2.x `authorize` goes through `Pundit::Context`, not `policy(record)`; overriding only `policy` fixes `policy_for_data` but not `authorize`
- **`Admin::ApplicationController` as single touch point** — no changes to `Core::Common` CRUD actions, `JsonResponse#policy_for_data`, or any existing controller

## Modified Files
Only `docs/superpowers/specs/2026-05-26-admin-rbac-module.md` was edited (not git-tracked — needs `git add`).

## Files to Read
- `docs/superpowers/specs/2026-05-26-admin-rbac-module.md` — full spec, sections 5-6 most relevant
- `app/controllers/concerns/core/authorizable.rb:40` — authorize override with Pundit fallback
- `app/services/core/auth_service.rb:8` — catches exceptions into Result.failure

## Next Steps
1. Get final user approval on the refined spec
2. `git add` the spec file and commit
3. Transition to implementation following Implementation Order (step 1: migration → step 14: auth regression tests)

## Open Questions
- None resolved in this session. Spec is ready for final approval.
