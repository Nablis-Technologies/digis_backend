# Phone-Based Event Scanner Invitations and Pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement after this plan is approved. Work test-first, preserve unrelated working-tree changes, and do not stage, commit, deploy, or reset data without an explicit request.

**Goal:** Replace UUID-based scanner setup and dual-token authentication with phone-based event invitations, single-use pairing capabilities, and one event-scoped scanner Bearer session.

**Architecture:** Ticketing owns scanner invitations, devices, event/device assignments, scoped sessions, delivery handoff, and scanner authentication. Events remains the authority for event staff roles; scanner invitations create an active `scanner` event assignment only after successful pairing. The existing outbox carries only invitation/assignment IDs and revisions, and the existing scanner sync/scan reconciliation contracts remain authoritative.

**Tech Stack:** Rails 8.1, Active Record/PostgreSQL, Core phone identity/idempotency/outbox, Pundit, Minitest, ActiveModelSerializers, Postman collection.

---

**Approved source:** [`docs/superpowers/specs/2026-10-07-phone-based-scanner-invitations-and-pairing-design.md`](../specs/2026-10-07-phone-based-scanner-invitations-and-pairing-design.md).

**Plan status:** Approved with the event-owned authorization rule; local implementation is complete and verified. Preview end-to-end verification remains pending a separately approved deployment.

## Execution status

- Implementation was completed on `feat/launch-hardening-telemetry` because the user explicitly asked to stay in this branch and not create a worktree.
- Preserve pre-existing untracked/modified files, especially the frontend gap tracker, scratch artifacts, and unrelated plans/specs.
- Local test database may be recreated to apply edited original migrations. Do not reset the development or Render preview database as part of this plan.
- No commits or staging are part of this plan; the user reviews and commits their own changes.

## Approved invariants

- SMS link, organizer-presented QR, and short code are delegated capabilities. Pairing does not prove the redeemer's natural-person identity or mark the invited phone verified.
- Link/QR capability is high entropy and single-use. The six-digit code is single-use, expires after 10 minutes, and permits at most three failed attempts plus per-source/per-invitation throttling.
- `Events::EventStaffAssignment` remains the human role authority; scanner access is event-scoped and never grants global `ORGANIZER` or finance permissions.
- Invitation authorization is event-owned: creation checks the organizer's current permission and persists a durable event-scoped grant. Pairing consumes that valid invitation without rechecking the creator's current role; explicit event-organizer revoke, event cancellation, or expiry invalidates the grant.
- Each scanner API call uses only `Authorization: Bearer <scanner_session_token>`. Remove the old normal-user-JWT plus `X-Scanner-Token` contract and separate device token. No compatibility shim is needed.
- `ScannerDevice` is a device identity/lifecycle record, not an authenticator. A `ScannerSession` is bound to one event, one event staff assignment, and one device.
- Revocation denies the next connected scanner request immediately. An offline device may continue only against its existing synchronized snapshot until expiry/reconnection; preserve this stated limitation.
- All-zone access means a snapshot of current zone IDs; newly created zones require an organizer scope update. Empty zones mean no zone access.
- Scanner access defaults to the latest scheduled event-date end plus six hours. If no finite schedule end exists, the organizer must supply a finite explicit end; event rescheduling never silently extends an issued session.
- One new database table per new migration file. Changes to existing scanner tables are made in their original migration files, and the disposable test database is rebuilt from the migration chain.

## Current code seams verified

- `Core::PhoneIdentity::ResolveOrCreate` normalizes Ethiopian E.164 phone numbers and has an authorized-manager path (`allow_actor_mismatch: true`) that can resolve/create an unverified shadow user. The scanner command must call it only after the organizer's invitation permission is established; it must not set phone verification state.
- `Events::EventStaffAssignment` supports `scanner` and active/suspended/revoked/expired states. `Events::StaffAssignments::Assign` accepts event, actor, user, organization, and role. The current event-staff create controller requires `user_id` and is not the new invite endpoint.
- `Ticketing::Scanners::RegisterDevice` currently returns a one-time device token; `AssignToEvent` currently creates event/device/zone scope but has no operator assignment link or controller route. Both need to be reshaped around pairing.
- `Ticketing::ScannerAuthenticated` currently runs after inherited Core authentication and requires the normal JWT plus `X-Scanner-Token`. Its scanner controllers pass `current_user` into admission/audit services. The new concern must explicitly skip normal auth/authorization on scanner-only endpoints, resolve a scoped session, and expose `current_scanner_operator`.
- `Core::Outbox::Publish` rejects secret-shaped payload keys and persists events transactionally. Ticketing already uses an outbox handler plus a delivery job that receives an invitation ID and decrypts capability material only at delivery time; use that boundary for scanner invites.
- `Events::StaffAssignments::Revoke` currently updates only the event-staff row. To reuse its route without a reverse module dependency, Event assignment status must be checked synchronously by scanner authentication; an Events-owned outbox event can then let Ticketing close the linked device assignment/session records.
- `Events::StaffAssignments::Assign` currently rechecks the actor's current permission, which conflicts with the approved event-owned grant. Add an Events-owned `AssignFromDelegatedGrant` command that accepts a narrow event/role/grantor/source grant from the trusted Ticketing pairing command, creates the event role, and audits original-grant attribution without importing or querying Ticketing classes.
- Existing scanner controllers/tests, parking admission tests, preview seeds, scanner fixtures, and the Postman collection currently construct or send device-token fields. All must be migrated to the one-session contract; preserve device-wide revoke idempotency receipts still used by `RevokeDevice`.

## File map

### New files

- `db/migrate/20261007090000_create_ticketing_scanner_invitations.rb` — create only `ticketing_scanner_invitations`.
- `db/migrate/20261007090001_create_ticketing_scanner_sessions.rb` — create only `ticketing_scanner_sessions`.
- `app/models/ticketing/scanner_invitation.rb` — encrypted invite phone/link/short-code material and lifecycle/revision state.
- `app/models/ticketing/scanner_session.rb` — keyed bearer-token digest, invitation/device-assignment binding, expiry, revocation; event/operator/device are derived through the assignment.
- `app/services/ticketing/scanners/create_invitation.rb`, `resend_invitation.rb`, `reset_pairing.rb`, `revoke_invitation.rb`, `update_assignment.rb`, and `pair_invitation.rb` — one lifecycle command per state transition.
- `app/services/ticketing/scanners/expire_invitations.rb` and `app/jobs/ticketing/expire_scanner_invitations_job.rb` — persist expiry/audit for pending and pairing-reset invites without creating staff/device assignments.
- `app/services/events/staff_assignments/assign_from_delegated_grant.rb` — create an event staff assignment from a validated one-use event grant without rechecking the grantor's current role.
- `app/values/events/staff_assignments/delegated_grant.rb` — typed event/role/grantor/source/issued-at authorization passed from Ticketing to Events; contains no phone or bearer secret.
- `app/services/ticketing/scanners/authenticate_session.rb` — resolve and validate the single scanner bearer session.
- `app/services/ticketing/outbox_handlers/revoke_scanner_assignment.rb` — idempotent Ticketing cleanup after an Events-owned staff-revoked event.
- `app/jobs/ticketing/deliver_scanner_invitation_job.rb` — receive invitation ID/revision only and invoke the configured delivery seam.
- `app/services/links/branded_url.rb` — build a scanner pairing URL from a configured scanner-app origin with the capability in the URL fragment.
- `app/controllers/ticketing/scanner_invitations_controller.rb` — authorized invite create/resend/reset/revoke endpoints.
- `app/controllers/ticketing/scanner_rosters_controller.rb` — safe event-scoped roster projection.
- `app/controllers/ticketing/scanner_device_assignments_controller.rb` — authorized active zone/window update.
- `app/controllers/ticketing/scanner/pair_controller.rb` — public capability exchange for a scanner session.
- `app/policies/ticketing/scanner_invitation_policy.rb` — event-scoped invitation visibility and lifecycle actions; extend existing scanner device/assignment policies for roster and scope actions.
- Focused model/service/job/controller/integration tests under the matching `test/models/ticketing`, `test/services/ticketing/scanners`, `test/jobs/ticketing`, `test/controllers/ticketing`, and `test/integration/ticketing` paths.

### Existing files to modify or remove

- Schema originals: `db/migrate/20260812090013_create_ticketing_scanner_devices.rb` (remove `token_digest` column/check/index) and `db/migrate/20260812090014_create_ticketing_scanner_device_assignments.rb` (add `event_staff_assignment_id`, FK, and active-scope constraints). Keep one `create_table` per migration.
- Scanner models/services: `app/models/ticketing/scanner_device.rb`, `app/models/ticketing/scanner_device_assignment.rb`, `app/services/ticketing/scanners/register_device.rb`, `assign_to_event.rb`, `revoke_device.rb`, and `idempotency_receipt.rb`. Remove `app/services/ticketing/scanners/rotate_token.rb`; preserve idempotency receipt behavior needed by device revoke.
- Scanner authentication/controllers: `app/controllers/concerns/ticketing/scanner_authenticated.rb`, `app/controllers/ticketing/scanner/auth_controller.rb` (remove old auth action/route), and the scanner `event_sync`, `scan_uploads`, `lookups`, and `verifications` controllers to use `current_scanner_operator`.
- Event-staff revoke/outbox boundary: `app/controllers/events/event_staff_assignments_controller.rb`, `app/services/events/staff_assignments/revoke.rb`, `config/initializers/ticketing_outbox_handlers.rb`, and focused Events revoke/outbox tests. Events publishes the scanner-revoked event; Ticketing consumes it. Scanner auth denies immediately from the revoked EventStaffAssignment state, even before cleanup delivery.
- Routing, delivery, scanner URL, and expiry configuration: `config/routes.rb`, `config/initializers/ticketing_outbox_handlers.rb`, `config/initializers/filter_parameter_logging.rb`, `config/initializers/short_links.rb`, `config/locales/ticketing/scanner.en.yml`, `config/recurring.yml`, and `postman/Digis API_collection.json`.
- Fixtures/seeds: `test/fixtures/ticketing_scanner_devices.yml`, `test/fixtures/ticketing_scanner_device_assignments.yml`, `db/seeds/preview.rb`, and `test/seeds_test.rb`.
- Existing regression tests to migrate: `test/services/ticketing/scanners/authenticate_test.rb`, `test/controllers/ticketing/scanner/{auth_controller,devices_controller,event_sync_controller,lookups_controller,scan_uploads_controller,verifications_controller}_test.rb`, scanner sync/admission/reversal/refund/offline tests, `test/integration/ticketing/checkin_corrections_test.rb`, `test/integration/ticketing/marketplace_scanner_privacy_test.rb`, and `test/integration/parking/parking_admission_test.rb`.
- Generated database snapshot: `db/structure.sql`.

## Task 1: Create the lifecycle schema and model invariants

**Files:** `db/migrate/20261007090000_create_ticketing_scanner_invitations.rb`, `db/migrate/20261007090001_create_ticketing_scanner_sessions.rb`, both original scanner migrations, both scanner models, `db/structure.sql`, new model tests, and `test/models/ticketing/scanner_admission_schema_test.rb`.

- [x] Write model tests first: invitation state allowlist and transition guards; encrypted phone/token/code accessors; token-digest uniqueness; one live invitation per event/phone digest; one live short-code digest at a time; code expiry/revision invariants; session token digest uniqueness and finite expiry; and scanner device assignment requires a matching event staff assignment.
- [x] Create `ticketing_scanner_invitations` in its own migration with UUIDv7, event/organization/creator references, encrypted phone/link/short-code columns, keyed digests, lifecycle/delivery state, revision, expiry, delivery attempt counter, and claimed operator/device/assignment references. Add FKs/checks and partial unique indexes for live `(event_id, phone_digest)` and live `pairing_code_digest`, plus unique high-entropy token digest and expiry/delivery indexes.
- [x] Create `ticketing_scanner_sessions` in a separate migration with UUIDv7, invitation and scanner-device-assignment references, unique keyed token digest, finite `expires_at`, `revoked_at`, and timestamps. Derive event, operator, and device through the linked assignment; do not duplicate those foreign keys. Add FKs, expiry/revocation checks, and lookup indexes.
- [x] Edit `20260812090013_create_ticketing_scanner_devices.rb` to remove the now-obsolete device token column, digest constraint, and digest index. Edit `20260812090014_create_ticketing_scanner_device_assignments.rb` to add required `event_staff_assignment_id` and its FK; derive the operator from this association, not a duplicated `operator_id`.
- [x] Implement model associations/validation and ensure `ScannerSession` stores only a keyed digest for its opaque token. Do not add a second table to either new migration.
- [x] Rebuild the disposable test database from the complete original migration chain and run the model/schema tests:

```bash
RAILS_ENV=test bin/rails db:migrate:reset
N_PLUS_ONE=1 bin/rails test \
  test/models/ticketing/scanner_invitation_test.rb \
  test/models/ticketing/scanner_session_test.rb \
  test/models/ticketing/scanner_admission_schema_test.rb
```

Observed: the full original migration chain completed, and the focused model/schema suite passed (15 tests, 46 assertions, 0 failures/errors). RuboCop passed on the 11 changed migration/model/test files; `db/structure.sql` contains both new tables and no scanner-device token column.

## Task 2: Implement organizer invitation lifecycle and roster/scope API

**Files:** scanner invitation commands, controllers, policies/serializers, `config/routes.rb`, `config/locales/ticketing/scanner.en.yml`, and matching service/controller/integration tests.

- [x] Add service/controller tests for authorized invite creation, normalized E.164 phone storage/digest, invalid phone, unauthorized organizer, idempotent same-key replay, changed request conflict, and safe one-time create response with `Cache-Control: no-store`.
- [x] Implement `CreateInvitation.call(event:, actor:, phone:, label:, zone_mode:, zone_ids:, starts_at:, ends_at:, expires_at:, idempotency_key:)`. It checks `Events::AuthorizationResolver.can_assign?(actor, event, "scanner")`, normalizes phone, derives the default access end from the latest scheduled date plus six hours, requires an explicit finite end when no date end exists, defaults invitation expiry to that finite access end (or accepts an earlier requested expiry), validates zones, and creates only a pending invite. No event staff assignment/device is active yet.
- [x] Implement resend/revoke/reset commands with row locks. Resend is pending-only and rotates capabilities; reset changes a paired invite to `pairing_reset`, revokes its prior scanner sessions/device assignment, preserves its event staff assignment, and issues a new capability. Every mutation binds actor and canonical request digest.
- [x] Add `GET /events/:event_id/scanners` as a roster projection with separate `invitations` and `assignments` arrays; include masked phone, label, safe delivery/access state, allowed zones, access window, and server-reconciled scan counts only. Do not return token/code digests or session material.
- [x] Add `PATCH /events/:event_id/scanner_device_assignments/:id` for authorized zone/window changes. Empty zone selection means no access; `all_current_zones` is converted to explicit IDs at update time. Revalidate ownership, event match, finite end, and time ordering under lock, then call `Events::Schedule::BumpVersion` in the same transaction so the next scanner delta includes the changed zone projection.
- [x] Require `Idempotency-Key` on create/resend/reset/revoke/update; use `Core::IdempotencyKeyResolver` and `IdempotencyAssertions`, plus integration coverage for missing key and exact replay.
- [x] Run the focused service/controller tests:

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/ticketing/scanners/create_invitation_test.rb \
  test/services/ticketing/scanners/resend_invitation_test.rb \
  test/services/ticketing/scanners/reset_pairing_test.rb \
  test/services/ticketing/scanners/revoke_invitation_test.rb \
  test/services/ticketing/scanners/update_assignment_test.rb \
  test/integration/ticketing/scanner_invitations_test.rb
```

Observed: 34 tests / 187 assertions passed under `N_PLUS_ONE=1`; RuboCop passed on 19 changed Ruby files; locale YAML parses. Event owners/managers can operate only on their event, cross-event IDs are hidden, replay creates no duplicate invite/audit, and roster responses contain no secret or unmasked phone.

## Task 3: Add durable delivery using the outbox secret boundary

**Files:** `app/jobs/ticketing/deliver_scanner_invitation_job.rb`, `app/services/links/branded_url.rb`, `config/initializers/short_links.rb`, `config/initializers/ticketing_outbox_handlers.rb`, scanner invite commands, sender configuration, and job/outbox tests.

- [x] Add tests proving a delivery job receives only invitation ID/revision, ignores expired/superseded invitations, decrypts token only inside the job boundary, and never logs or stores the token in outbox payloads. Test that scanner URLs carry the capability in a fragment, not a path or query.
- [x] In the same DB transaction as create/resend/reset, publish a `ticketing.scanner_invitation.delivery_requested` event containing only `invitation_id` and `delivery_revision`; compute its deterministic outbox key with `Core::KeyedDigest.digest(namespace: "ticketing/scanner-invitation-delivery", value: "#{invitation.id}:#{delivery_revision}")`.
- [x] Register the handler in `config/initializers/ticketing_outbox_handlers.rb`; it enqueues `DeliverScannerInvitationJob` with invitation ID and revision only. Add a `scanner_invitation_delivery_sender` injection seam defaulting to a no-op; do not add an SMS provider adapter in Ticketing.
- [x] Read optional `SCANNER_APP_URL` in `config/initializers/short_links.rb` (defaulting to `PUBLIC_APP_URL`) and build pairing links with an invitation path and fragment-only capability; the frontend removes this fragment from browser history after exchange. Configure Render with the scanner origin when the PWA is deployed there.
- [x] Record `queued`, `accepted`, `delivered` when supported by the sender, `failed`, or `unknown` separately from invitation state. Retry only the same live revision; resend creates a new revision and invalidates prior capabilities.
- [x] Run:

```bash
N_PLUS_ONE=1 bin/rails test \
  test/jobs/ticketing/deliver_scanner_invitation_job_test.rb \
  test/jobs/core/process_outbox_job_test.rb \
  test/services/core/outbox/publish_test.rb
```

Observed: scanner delivery/outbox tests pass; RuboCop passed on the 6 changed job/link/initializer/test files; the locale YAML parses. No SMS adapter or provider credential was added.

## Task 4: Implement capability redemption and one-token scanner session issuance

**Files:** `app/services/ticketing/scanners/pair_invitation.rb`, `app/services/events/staff_assignments/assign_from_delegated_grant.rb`, `app/values/events/staff_assignments/delegated_grant.rb`, `app/controllers/ticketing/scanner/pair_controller.rb`, routes, scanner invitation/session models, `RegisterDevice`, `AssignToEvent`, and service/controller/concurrency tests.

- [x] Write failing tests for valid magic-link, organizer-QR, and short-code claim; wrong/expired/revoked/replayed capability; active-code collision retry; no OTP; no `phone_verified_at` mutation; exactly-one concurrent claimant; three short-code attempts per installation within 10 minutes plus IP throttling; reset pairing reusing the existing staff assignment; and no duplicate device/session/assignment on retries.
- [x] Implement capability exchange in `PairInvitation`; accept one capability only, compare keyed digests, enforce single use, 10-minute code expiry, three attempts per installation, and a per-IP cache throttle. Request IP is only a throttle input, not proof of physical presence.
- [x] Resolve the operator through `Core::PhoneIdentity::ResolveOrCreate` only after the persisted invitation proves organizer authorization. The flow leaves phone verification and global roles unchanged.
- [x] Under one transaction and invitation lock, create/reuse the event staff assignment, register the device identity, create the event-scoped device assignment and zone mappings, and persist only the session token digest. The Events-owned delegated-grant command preserves original-inviter attribution without rechecking the inviter's current role or depending on Ticketing. Pairing reset reuses the active event staff assignment.
- [x] Generate a high-entropy scanner session token, persist only its keyed digest, return it only on first successful pairing, and make exact replays safe without returning an earlier plaintext session token.
- [x] Resolve `all_current_zones` to an active-zone snapshot under the event lock; validate exact selected zones and preserve empty selection as no zone access.
- [x] Add capability-only `POST /scanner/pair`, require `Idempotency-Key`, bypass normal user JWT auth only on this endpoint, and return the scoped session/event/assignment/zones/expiry with no-store headers.
- [x] Run the focused pairing, concurrent claim, scope, and endpoint tests:

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/ticketing/scanners/pair_invitation_test.rb \
  test/values/events/staff_assignments/delegated_grant_test.rb \
  test/services/events/staff_assignments/assign_from_delegated_grant_test.rb \
  test/integration/ticketing/scanner_pairing_test.rb \
  test/services/ticketing/scanners/pair_invitation_concurrency_test.rb
```

Observed: both pairing methods pass without OTP or false phone verification; the inviter's later role removal does not invalidate the event-owned grant; expired/revoked capabilities fail; exact concurrent retries create one session and return safe replay state; different-key concurrent claims have exactly one winner.

## Task 5: Switch all scanner requests to the unified Bearer session; remove legacy device credentials

**Files:** `app/controllers/concerns/ticketing/scanner_authenticated.rb`, scanner sync/upload/lookup/verification controllers, `Authenticate` replacement, `ScannerDevice`, `RegisterDevice`, `ScannerDevicesController`, routes, seeds/fixtures, Postman, and all scanner-dependent tests.

- [x] Add tests for valid session Bearer-only auth; missing/invalid/expired/revoked sessions; event/device/staff/window scope; cross-event use; and rejection of user JWT plus the retired header.
- [x] Implement `AuthenticateSession` with keyed-digest lookup, bounded eager loading, event/staff/device/assignment/window/expiry checks, device last-seen update, and a resolved scanner operator.
- [x] Update scanner controllers and `ScannerAuthenticated` to use `current_scanner_operator` and bypass normal Core JWT authentication only for scanner-session endpoints.
- [x] Remove `/scanner/auth`, `X-Scanner-Token`, scanner request `device_identifier` parameters, device token digests/helpers, `RotateToken`, and the rotate route. Keep organization-scoped device listing/revocation and digest-only revoke receipts.
- [x] Update scanner tests/helpers, preview seed expectations, parking, concurrency/refund/offline suites, and controller tests. Test helpers create real pairing sessions; fixtures contain no plaintext scanner credentials.
- [x] Search for the retired authentication contract; `device_identifier` remains only as generated device identity/pairing data and device management, never on scanner request URLs:

```bash
rg -n 'X-Scanner-Token|ScannerDevice\.token_digest|RotateToken|rotate_token' \
  app test config/routes.rb db/seeds postman/Digis\ API_collection.json
rg -n 'device_identifier' app/controllers/ticketing/scanner app/controllers/concerns/ticketing/scanner_authenticated.rb postman/Digis\ API_collection.json
```

Observed: scanner runtime, routes, preview seeds, and Postman have no device-token/auth/rotation contract. The only remaining X-Scanner-Token occurrences are negative tests proving the retired header is rejected.

- [x] Run all scanner and admission regression suites with N+1 detection.

```bash
N_PLUS_ONE=1 bin/rails test \
  test/controllers/ticketing/scanner \
  test/services/ticketing/scanners \
  test/services/ticketing/scanner_sync \
  test/services/ticketing/admissions \
  test/services/ticketing/zones \
  test/integration/ticketing/offline_scan_conflict_test.rb \
  test/integration/ticketing/admission_concurrency_test.rb \
  test/integration/ticketing/admission_reversal_concurrency_test.rb \
  test/integration/ticketing/checkin_corrections_test.rb \
  test/integration/ticketing/marketplace_scanner_privacy_test.rb \
  test/integration/ticketing/refund_entry_race_test.rb \
  test/integration/parking/parking_admission_test.rb
```

Expected: existing scanner credential validation and server reconciliation behavior remains unchanged, but every scanner HTTP request uses one session Bearer token.

## Task 6: Complete revoke, cancellation, reset, expiry, and scope-change lifecycle

**Files:** `app/controllers/events/event_staff_assignments_controller.rb`, `app/services/events/staff_assignments/revoke.rb`, `config/initializers/ticketing_outbox_handlers.rb`, `config/recurring.yml`, new Ticketing outbox handler, expiry job/command, `RevokeDevice`, invitation/session services, access-zone assignment update, and lifecycle tests.

- [x] Require `Idempotency-Key` on event-staff revoke. The Events service is idempotent, treats already-revoked assignments as safe no-ops, and publishes a deterministic scanner cleanup event for scanner roles only.
- [x] Verify Events publishes cleanup evidence transactionally without depending on Ticketing; controller tests cover missing keys and duplicate replay.
- [x] Add idempotent Ticketing cleanup for revoked staff assignments. Scanner auth denies immediately from the Events row before the outbox is delivered; cleanup then revokes device assignments, sessions, and the paired invitation state.
- [x] Extend `RevokeDevice` to revoke all bound sessions and active/suspended assignments atomically while retaining audit, required reason, and revoke-receipt replay behavior.
- [x] On `events.cancellation_initiated`, close all scanner sessions/assignments and revoke live invitations through a Ticketing handler; connected auth is denied immediately from event status.
- [x] Add bounded `ExpireInvitations` and `ExpireScannerInvitationsJob` on the recurring schedule. The command locks due pending/reset invitations, clears encrypted capability material, and writes one audit/outbox transition; pair/roster also enforce expiry synchronously.
- [x] Test reset/re-pair: old session and assignment are revoked; the event staff assignment remains active and is reused; previous credentials cannot pair again.
- [x] Test scope updates: selected zones are exact, all-current zones are snapshotted under the event lock, empty selected zones grant none, windows are finite, and updates bump the scanner schedule cursor.
- [x] Run lifecycle regressions with N+1 detection.

```bash
N_PLUS_ONE=1 bin/rails test \
  test/services/events/staff_assignments/revoke_test.rb \
  test/services/ticketing/scanners/revoke_device_test.rb \
  test/services/ticketing/outbox_handlers/revoke_scanner_assignment_test.rb \
  test/services/ticketing/scanners/expire_invitations_test.rb \
  test/services/ticketing/outbox_handlers/cancel_event_scanner_access_test.rb \
  test/jobs/ticketing/expire_scanner_invitations_job_test.rb \
  test/integration/events/event_staff_assignments_test.rb \
  test/integration/events/event_cancellations_test.rb \
  test/integration/ticketing/scanner_invitations_test.rb
```

Expected: existing revoke URL still works for all event roles; scanner state is cleaned without an Events-to-Ticketing dependency; offline scans remain immutable and reconcile under the existing contract.

## Task 7: Synchronize API contract and run final verification

**Files:** `postman/Digis API_collection.json`, scanner docs/fixtures only if the payload/auth contract changed, locales/filtering, schema snapshot, and focused regression suites.

- [x] Add Postman examples for invite create, roster, resend, reset pairing, capability pairing, scope update, event revoke, device listing/revoke, and scanner operations. Scanner requests use only `Authorization: Bearer {{scannerSessionToken}}`; old device-token variables and `/scanner/auth` are removed.
- [x] Update the v3 scanner architecture/runbook, locales, and parameter filtering. Scanner sync payload stayed unchanged, so its contract version and fixture were not bumped.
- [x] Run the full feature matrix with N+1 detection, then changed-source RuboCop, Zeitwerk, JSON/YAML validation, and whitespace checks:

```bash
N_PLUS_ONE=1 bin/rails test \
  test/models/ticketing/scanner_invitation_test.rb \
  test/models/ticketing/scanner_session_test.rb \
  test/services/ticketing/scanners \
  test/services/ticketing/scanner_sync \
  test/controllers/ticketing/scanner \
  test/jobs/ticketing/deliver_scanner_invitation_job_test.rb \
  test/jobs/ticketing/expire_scanner_invitations_job_test.rb \
  test/services/ticketing/scanners/expire_invitations_test.rb \
  test/services/ticketing/outbox_handlers \
  test/integration/ticketing/scanner_invitations_test.rb \
  test/integration/ticketing/scanner_pairing_test.rb \
  test/integration/ticketing/offline_scan_conflict_test.rb \
  test/integration/ticketing/admission_concurrency_test.rb \
  test/integration/ticketing/admission_reversal_concurrency_test.rb \
  test/integration/ticketing/checkin_corrections_test.rb \
  test/integration/ticketing/marketplace_scanner_privacy_test.rb \
  test/integration/parking/parking_admission_test.rb \
  test/integration/events/event_staff_assignments_test.rb \
  test/integration/events/event_cancellations_test.rb
bundle exec rubocop
bin/rails zeitwerk:check
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json"))'
git diff --check
```

- [x] Review feature paths and search for retired token/route names. The retired contract is absent from application code/routes/seeds/Postman; raw capability remains only in authorized no-store responses and the delivery boundary, never in outbox/audit metadata.
- [ ] After local verification and a user-approved deployment, run preview E2E: create invitation by phone, verify delivery material/code, pair without OTP, authenticate scanner API with one Bearer token, sync and perform a scan, update zone scope, revoke the event assignment, verify connected denial, and verify offline stale-window behavior after reconnect. Do not reset Render data unless separately approved.

**Observed final local verification:** 219 tests / 1,173 assertions passed under `N_PLUS_ONE=1`; 101 changed/feature Ruby files passed RuboCop with no offenses; Zeitwerk reported “All is good”; Postman JSON and changed locale YAML parsed; `git diff --check` passed. A separate whole-repository RuboCop run reported 251 workspace offenses, including many in unrelated untracked scratch scripts; those user-owned files were left untouched. Render deployment and live preview E2E remain pending.

## Completion criteria

- Phone-based invite and claim work without a user UUID or mandatory OTP; phone verification state remains truthful.
- Invitation delivery is durable and secret-safe; resend/reset invalidates old capabilities.
- Scanner requests use one event-scoped session token only; no device-token compatibility code remains.
- Event staff, device assignment, zone access, session, and expiry boundaries are enforced; event revoke works without module dependency inversion.
- Existing scanner credential validation, offline snapshot application, upload replay, admission-use allocation, and reconciliation pass regression coverage.
- One migration creates one table, edited originals match the source schema, Postman matches the API, and all focused tests/lint/boot checks pass.
- Deployment/live E2E remains unverified until a separately authorized deployment is available; no Render reset/deploy is part of this plan.
