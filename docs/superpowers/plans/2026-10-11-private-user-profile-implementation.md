# Private User Profile and Self-Service Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Keep changes on the current branch; do not create a worktree. Leave changes unstaged and uncommitted for the user to review.

**Goal:** Persist first/last names and an optional private avatar, expose an owner-scoped `/user` resource, and show account-holder names only through authorized event-scoped attendee data.

**Architecture:** Add one optional 1:1 `Core::UserProfile` table and create it transactionally during signup. Split current-user serialization from non-self summaries, and route self reads/updates through `Core::UsersController` and an idempotent profile command. Validate and pre-process avatar uploads before replacement; serve only an authenticated fixed thumbnail. Expose the account-holder name as a permission-gated attendee-export field without replacing form answers.

**Tech Stack:** Rails 8.1, Active Record, Active Storage, ActiveModelSerializers, Pundit, Minitest, PostgreSQL `structure.sql`, Postman.

**Implementation status:** Local implementation and verification are complete. The scoped profile/auth/export acceptance set passes under `N_PLUS_ONE=1` (142 tests, 884 assertions); the full suite passes (4,078 tests, 19,298 assertions, 0 failures/errors, 5 skips). Focused RuboCop passes on all 32 changed Ruby files. Strict loading is asserted only around profile/auth projection requests; repository-wide strict-loading changes are explicitly out of scope. Preview verification remains pending deployment.

---

## Source specification

Implement `docs/superpowers/specs/2026-10-11-private-user-profile-design.md`. This plan is backend-only; the frontend repository is unavailable. Coordinate `/auth/me` removal with the frontend cutover.

## File map

- New migration: `db/migrate/20261011090000_create_core_user_profiles.rb` (one table only).
- New model/test: `app/models/core/user_profile.rb`, `test/models/core/user_profile_test.rb`; add optional association in `app/models/core/user.rb`.
- Signup: modify `app/controllers/core/auth_controller.rb`, `app/services/core/signups/complete.rb`, `test/integration/core/auth_test.rb`.
- Serialization: create `app/serializers/core/current_user_serializer.rb`, `app/serializers/core/user_profile_serializer.rb`, `app/serializers/core/user_summary_serializer.rb`; update auth, guest registration, public ticket-transfer, and membership serializer call sites; delete `app/serializers/core/user_auth_serializer.rb` after references are removed. The membership summary is exactly `id`, `email`, and `phone` in its existing organization-scoped context; no profile or RBAC fields.
- Self API: create `app/controllers/core/users_controller.rb`, `app/policies/core/user_policy.rb`, `test/integration/core/users_test.rb`; update `config/routes.rb` and existing auth tests.
- Mutation: create `app/services/core/user_profiles/update.rb` and `app/services/core/user_profiles/avatar_upload.rb`; test at `test/services/core/user_profiles/update_test.rb`.
- Event-scoped attendee display: update `app/services/ticketing/exports/field_registry.rb`, `app/services/ticketing/exports/generate.rb`, and their field-registry/generate/request/policy/integration tests.
- Contracts/config: update `config/locales/core/user.en.yml`, `config/locales/ticketing/attendee_exports.en.yml`, `config/environments/test.rb` if strict loading is not active, `postman/Digis API_collection.json`, and generated `db/structure.sql`.

No seed/backfill, existing-table migration, or database reset is part of this feature. Do not infer names for existing accounts.

## Tasks

### Task 1: Add the profile table and model

**Files:** migration above; `app/models/core/user_profile.rb`; `app/models/core/user.rb`; `test/models/core/user_profile_test.rb`; generated `db/structure.sql`.

- [ ] Write model tests for NFC normalization, trimmed names, Ge'ez/Amharic, computed `full_name`, blank/control/overlong rejection, and unique one-profile-per-user association.
- [ ] Run `bin/rails test test/models/core/user_profile_test.rb`; confirm it fails because the model/association do not exist.
- [ ] Add a single migration with UUIDv7, non-null `first_name`/`last_name` (`limit: 100`), timestamps, non-null FK to `core_users`, and unique index on `user_id`. Do not create Active Storage tables or avatar columns.
- [ ] Add `belongs_to :user`, `has_one_attached :avatar` with the named `thumb` 200x200 `resize_to_fill` variant, Unicode NFC/trim/control/length validation, computed `full_name`, and explicit Ransack allow-lists. Add optional `has_one :profile` to `Core::User`.
- [ ] Run `bin/rails db:migrate` then `bin/rails test test/models/core/user_profile_test.rb`; expect one new table and passing tests.

### Task 2: Persist names atomically in signup

**Files:** `app/controllers/core/auth_controller.rb`; `app/services/core/signups/complete.rb`; `test/integration/core/auth_test.rb`.

- [ ] Add failing OTP-signup cases for required names, Unicode names, profile creation, profile-write rollback, exact replay, and same key with changed names.
- [ ] Run `bin/rails test test/integration/core/auth_test.rb`; confirm the new assertions fail.
- [ ] Permit `first_name`/`last_name` in signup params. Create `Core::UserProfile` inside `Complete#upgrade_shadow!`'s existing transaction, after user upgrade and before signup audit.
- [ ] Add normalized first/last names to the keyed signup request digest so same-key payload changes conflict. Keep raw names out of audit changes/metadata. Exact replay must not create another profile/audit.
- [ ] Run `bin/rails test test/integration/core/auth_test.rb`; expect signup, replay, and rollback coverage to pass.

Implementation shape for profile creation inside the existing transaction:

```ruby
Core::UserProfile.create!(
  user: user,
  first_name: @attributes[:first_name],
  last_name: @attributes[:last_name]
)
```

### Task 3: Separate self and non-self serializers

**Files:** three new serializers listed in the file map; auth/guest/membership controllers and serializers; `test/integration/core/auth_test.rb`, `test/integration/organizations/owner_team_rosters_test.rb`, `test/integration/ticketing/registration_workflows_test.rb`, `test/integration/ticketing/public_ticket_transfers_test.rb`.

- [ ] Add tests proving auth/self responses preserve existing fields and roles/permissions types while adding nested profile or null; membership responses do not inherit profile/avatar/RBAC fields.
- [ ] Run the focused auth/roster/claim tests and confirm failures.
- [ ] `Core::CurrentUserSerializer` owns existing auth fields, roles, permissions and the nested profile; `Core::UserProfileSerializer` emits only first/last/full name and relative `/user/avatar` or null. Keep the roles/permissions wire contract unchanged.
- [ ] `Core::UserSummarySerializer` is the exact minimal membership projection `{ id, email, phone }`, preserving the currently exposed organization-scoped contact fields while dropping verification, timestamps, roles, permissions, and profile data. Use current-user serialization for guest registration/ticket-transfer claim responses that return that user's tokens.
- [ ] Update all `Core::UserAuthSerializer` references, then delete its file. Run `rg -n 'Core::UserAuthSerializer' app test`; expect no references.
- [ ] Independently preload `roles: :permissions` and `profile: { avatar_attachment: :blob }` for current-user serialization. Do not put rendering preloads in `Core::AuthService` or guard the profile preload on roles already being loaded.
- [ ] Run auth, membership roster, guest registration, and transfer integration tests; expect no profile leak and matching self projections.

### Task 4: Add `/user` and remove `/auth/me`

**Files:** `app/controllers/core/users_controller.rb`; `app/policies/core/user_policy.rb`; `config/routes.rb`; `app/controllers/core/auth_controller.rb`; `config/locales/core/user.en.yml`; `test/integration/core/auth_test.rb`; new `test/integration/core/users_test.rb`.

- [ ] Add failing tests for direct `data` user shape, null profile for shadow users, read-no-write, authenticated owner scope, 401 without auth, and removed `/auth/me` route.
- [ ] Run `bin/rails test test/integration/core/users_test.rb`; confirm route/action tests fail.
- [ ] Add singular `resource :user, only: %i[show update], controller: 'core/users'` and `GET /user/avatar`. Remove `/auth/me` route and `AuthController#me`; do not keep an alias.
- [ ] Define `Core::UserPolicy` checks for `show?`, `update?`, and `avatar?` requiring the record to be `current_user`. `UsersController#show` serializes the authorized current user directly as `data`; it never creates a profile. Set private/no-store on JSON.
- [ ] Keep strict-loading assertions scoped to profile/auth projection requests via `Core::CurrentUserProjectionTestHelpers`; do not change the global test setting or clean up unrelated domains. This scope was explicitly chosen after the global experiment surfaced unrelated repository-wide failures.
- [ ] Run `bin/rails test test/integration/core/users_test.rb test/integration/core/auth_test.rb`; expect direct data shape, owner-only access, no read side effect, and no `/auth/me` route.

### Task 5: Add idempotent profile updates

**Files:** `app/services/core/user_profiles/update.rb`; `app/controllers/core/users_controller.rb`; `app/policies/core/user_policy.rb`; `config/locales/core/user.en.yml`; new `test/services/core/user_profiles/update_test.rb`; `test/integration/core/users_test.rb`.

- [ ] Add failing tests for first profile creation, partial updates to existing profiles, missing Idempotency-Key, exact replay, changed-payload conflict, single audit, and audit-value privacy.
- [ ] Run `bin/rails test test/services/core/user_profiles/update_test.rb test/integration/core/users_test.rb`; confirm failures.
- [ ] Implement `Core::UserProfiles::Update.call(user:, attributes:, idempotency_key:, request:)`. The controller permits only nested first/last/avatar/remove fields and requires the shared Idempotency-Key resolver.
- [ ] Lock the user/profile during mutation. Use `Core::IdempotencyKey`, a stable audit key, and keyed canonical request digest. First creation requires both names; PATCH on an existing profile leaves omitted values unchanged.
- [ ] Record actor/profile IDs, operation, changed field names and digest only. Never record names, file bytes, filenames, blob keys, or signed URLs. Same key/payload is a no-op replay; changed payload conflicts.
- [ ] Run the service and integration tests; expect idempotency and privacy assertions to pass.

### Task 6: Validate avatar ingestion and replacement

**Files:** `app/services/core/user_profiles/avatar_upload.rb`; `app/services/core/user_profiles/update.rb`; `app/models/core/user_profile.rb`; core user locale; service/integration tests.

- [ ] Add failing cases using `test/fixtures/files/pixel.png`, spoofed MIME, malformed bytes, >5 MiB, upload plus `remove_avatar`, processor/storage failure, and preservation of the old avatar after a failed replacement.
- [ ] Run the focused profile update tests and confirm failures.
- [ ] Reject files over 5 MiB before decode; validate actual file bytes with the configured image decoder and successfully generate the fixed `thumb` variant before swapping the existing attachment.
- [ ] Return 422 `invalid_avatar` only for malformed/unsupported user input; return generic 503 `avatar_processing_unavailable` for unexpected processor/storage failures. Clean unattached blobs and leave the old avatar unchanged on either failure.
- [ ] If a new file and truthy `remove_avatar` are both supplied, return 422 `avatar_operation_conflict` before mutation. Parse multipart false values correctly; never silently prioritize an operation.
- [ ] Include file content in the idempotency identity using a keyed digest, not raw bytes. Prove same-file retry is a no-op and different file under the same key conflicts.
- [ ] Run profile service and integration tests; expect validation, conflict, failed replacement, replay and audit tests to pass.

### Task 7: Serve the avatar privately with ETag

**Files:** `app/controllers/core/users_controller.rb`; `app/policies/core/user_policy.rb`; `test/integration/core/users_test.rb`.

- [ ] Add failing tests for unauthenticated 401, absent-avatar 404 `avatar_not_found`, image response, ETag, matching `If-None-Match` 304 with empty body, changed ETag after replacement, and authorization before a 304.
- [ ] Run the user integration test and confirm failures.
- [ ] Authorize current user before evaluating conditional headers. Return 404 for no profile/attachment. Serve the processed 200x200 variant through the authenticated endpoint; never redirect to an Active Storage signed URL.
- [ ] Set avatar byte responses to `Cache-Control: private, max-age=0, must-revalidate`; use an opaque profile/avatar-revision ETag with no PII/storage key. Handle unexpected serving failures as generic 503 `avatar_unavailable`.
- [ ] Run `bin/rails test test/integration/core/users_test.rb`; expect all auth, 404, ETag/304 and privacy checks to pass under strict loading.

### Task 8: Add event-scoped account-holder name to attendee export

**Files:** `app/services/ticketing/exports/field_registry.rb`; `app/services/ticketing/exports/generate.rb`; attendee-export locale; field registry/generate/request/policy/integration tests.

- [ ] Add failing tests for selector `registration_user_full_name`, `attendee_export.contact` gating, registration/admission row modes, and separation from form-answer selectors.
- [ ] Run the focused attendee-export test set and confirm the new selector is rejected/not emitted.
- [ ] Add `registration_user_full_name` as a fixed built-in with heading `Registration Account Holder Name`, gated by the existing `attendee_export.contact` permission. Extract `registration.user.profile.full_name`, blank when profile absent.
- [ ] Preload `user: :profile` in export generation. Do not include avatars or profile values in public serializers/scanner synchronization.
- [ ] Keep account-holder name as a distinct export column. Never fill or overwrite form answers; those remain the attendee's authoritative name/answers when a ticket is purchased for another person.
- [ ] Run `bin/rails test test/services/ticketing/exports/field_registry_test.rb test/services/ticketing/exports/generate_test.rb test/services/ticketing/exports/request_test.rb test/policies/ticketing/attendee_export_policy_test.rb test/integration/ticketing/attendee_exports_test.rb`; expect authorization and answer-precedence tests to pass.

### Task 9: Sync Postman and complete verification

**Files:** `postman/Digis API_collection.json`; core and attendee-export locales; `db/structure.sql`; files from Tasks 1–8.

- [ ] Remove `/auth/me` from Postman. Add GET/PATCH `/user`, multipart avatar upload/removal, GET `/user/avatar` ETag/conditional examples, signup first/last names, and the `registration_user_full_name` export selector. Do not include credentials or signed blob URLs.
- [ ] Run `bin/rails routes | rg '(^|/)(user|auth/me)'`; expect `/user`, `/user/avatar`, PATCH `/user`, and no `/auth/me`.
- [ ] Run focused tests with `N_PLUS_ONE=1`: `bin/rails test test/models/core/user_profile_test.rb test/services/core/user_profiles/update_test.rb test/integration/core/auth_test.rb test/integration/core/users_test.rb test/services/ticketing/exports/field_registry_test.rb test/services/ticketing/exports/generate_test.rb test/services/ticketing/exports/request_test.rb test/policies/ticketing/attendee_export_policy_test.rb test/integration/ticketing/attendee_exports_test.rb test/integration/organizations/owner_team_rosters_test.rb test/integration/ticketing/registration_workflows_test.rb test/integration/ticketing/public_ticket_transfers_test.rb`; expect PASS.
- [ ] Run `bin/rails test`; expect PASS.
- [ ] Run RuboCop with caching disabled on the changed Ruby files; expect zero offenses. A repository-wide pass currently reports unrelated offenses outside this feature; do not expand scope to fix them.
- [ ] Run `bin/rails zeitwerk:check`; expect `All is good!`.
- [ ] Run `git diff --check`; expect no whitespace errors.
- [ ] After user deploys, do a non-destructive preview smoke test for signup names, `/user` response shape, avatar upload/replay/ETag/404 behavior, and permission-gated export. Do not reset Render DB or seed guessed names; confirm the configured image processor generates the 200x200 variant.

## Spec coverage check

- Profile model, Unicode, optional account lifecycle and no guessed backfill: Tasks 1–2.
- Exact self wire projection, auth serializer isolation, `/user` and `/auth/me` cutover: Tasks 3–4.
- Idempotent update, audit privacy, avatar conflict and failed replacement: Tasks 5–6.
- Private avatar 404/ETag/304 and operational failure behavior: Task 7.
- Event-scoped account-holder visibility without replacing attendee answers: Task 8.
- Postman, strict loading, tests, RuboCop, Zeitwerk and preview smoke: Task 9.

## Handoff constraints

- Do not stage or commit changes; the user reviews and commits.
- Do not create a worktree or reset any database.
- Do not add profile fields to public serializers, generic membership summaries, or scanner sync.
- Do not expose profile data through Ransack, admin-user output, audit values, logs, or storage URLs.

