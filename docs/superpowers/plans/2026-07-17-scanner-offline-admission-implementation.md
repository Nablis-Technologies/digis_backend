# Scanner Offline Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build authenticated online/offline scanning, versioned synchronization, PNR/manual recovery, zones, ID matching, idempotent uploads, authoritative first-scan-wins reconciliation, and append-only admission-use reversal.

**Architecture:** Scanner assignments download versioned revocation, attendee-index, schedule/zone, and reversal deltas. QR and manual lookup produce the same `Ticketing::CredentialClaims` and call the package plan's validator. Local SQLite mirrors that contract; PostgreSQL remains authoritative when uploads reconcile under deterministic locks.

**Tech Stack:** Rails 8.1 API-only, Ruby 3.4, PostgreSQL UUIDs/locks/partial indexes, Pundit, ActiveModelSerializers, Solid Queue, Ed25519 public-key verification, native SQLite, Minitest and JSON contract fixtures.

---

**Authoritative specifications:**

- `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`
- `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`

**Prerequisite:** Complete the core-foundation plan and Tasks 1–4 of the ticket-package plan. Reuse `Ticketing::CredentialClaims`, `Ticketing::Credentials::Validator`, typed `Core::BusinessError`, outbox/audit/idempotency/advisory-lock infrastructure; do not create scanner-only validators or symbol/hash failures.

**Lock order:** scanner assignment, upload, ticket, active generation, credential, slots by position, product access, uses by slot/number, check-in. Reversal locks original check-in, its uses by ID, slot/access scopes, then event reversal version.

## Execution route

Start this plan after Orders Tasks 7–9 and Ticket Packages Tasks 2–6 are
green. Scanner can run as a Wave 5 track alongside Refunds/Finance, but it
must consume the Ticket Packages validator and generation/revocation contract;
do not add a scanner-specific credential validator. The serialized
single-worktree route therefore begins here at Task 1; Refunds/Finance Task 1
remains the independent Wave 5 track.

## Task 1: Create scanner, check-in, use, upload, and reversal schema

**Files:**
- Create: `db/migrate/20260812090013_create_ticketing_scanner_devices.rb`
- Create: `db/migrate/20260812090014_create_ticketing_scanner_device_assignments.rb`
- Create: `db/migrate/20260812090015_create_ticketing_scanner_assignment_zones.rb`
- Create: `db/migrate/20260812090016_create_ticketing_scan_uploads.rb`
- Create: `db/migrate/20260812090017_create_ticketing_checkin_logs.rb`
- Create: `db/migrate/20260812090018_create_ticketing_admission_uses.rb`
- Create: `db/migrate/20260812090019_create_ticketing_admission_use_reversals.rb`
- Create: `app/models/ticketing/scanner_device.rb`
- Create: `app/models/ticketing/scanner_device_assignment.rb`
- Create: `app/models/ticketing/scanner_assignment_zone.rb`
- Create: `app/models/ticketing/scan_upload.rb`
- Create: `app/models/ticketing/checkin_log.rb`
- Create: `app/models/ticketing/admission_use.rb`
- Create: `app/models/ticketing/admission_use_reversal.rb`
- Test: `test/models/ticketing/scanner_admission_schema_test.rb`
- Test fixtures: `test/fixtures/ticketing_scanner_devices.yml`, `test/fixtures/ticketing_scanner_device_assignments.yml`, `test/fixtures/ticketing_checkin_logs.yml`, `test/fixtures/ticketing_admission_uses.yml`

- [x] **Step 1: RED — test database idempotency and history constraints**

```ruby
require "test_helper"

class Ticketing::ScannerAdmissionSchemaTest < ActiveSupport::TestCase
  test "client scan id is globally unique" do
    duplicate = ticketing_checkin_logs(:friday_group_success).dup
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "usage ordinal is unique per slot and access" do
    duplicate = ticketing_admission_uses(:slot_one_friday).dup
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end
end
```

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/scanner_admission_schema_test.rb`

Expected: FAIL because schema is missing.

- [x] **Step 3: GREEN — implement exact constraints and indexes**

```ruby
add_index :ticketing_scanner_devices, :device_identifier, unique: true
add_index :ticketing_scanner_devices, :token_digest, unique: true
add_index :ticketing_scanner_device_assignments, %i[scanner_device_id event_id], unique: true,
  where: "status = 'active'", name: "idx_active_scanner_assignment"
add_index :ticketing_scanner_assignment_zones,
  %i[scanner_device_assignment_id access_zone_id], unique: true
add_index :ticketing_scan_uploads,
  %i[scanner_device_assignment_id client_upload_id], unique: true
add_index :ticketing_checkin_logs, :client_scan_id, unique: true
add_index :ticketing_checkin_logs, :overrides_checkin_log_id, unique: true,
  where: "overrides_checkin_log_id IS NOT NULL"
add_index :ticketing_admission_uses,
  %i[admission_slot_id product_access_id usage_number], unique: true
add_index :ticketing_admission_use_reversals, :admission_use_id, unique: true
add_index :ticketing_admission_use_reversals, %i[event_id reversal_version]
```

Create all fields from Sections 8.10–8.14. Add sync-version/status/result/lookup/identity/usage checks, assignment windows, override all-or-none fields, and a deferred trigger requiring one reversal group to reference one successful group check-in and reverse every use it created.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/scanner_admission_schema_test.rb`

Expected: PASS.

- [x] **Step 5: REFACTOR — keep models declarative**

No callbacks determine scan results, allocate ordinals, or bump feed versions.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add db/migrate/20260812090013_create_ticketing_scanner_devices.rb db/migrate/20260812090014_create_ticketing_scanner_device_assignments.rb db/migrate/20260812090015_create_ticketing_scanner_assignment_zones.rb db/migrate/20260812090016_create_ticketing_scan_uploads.rb db/migrate/20260812090017_create_ticketing_checkin_logs.rb db/migrate/20260812090018_create_ticketing_admission_uses.rb db/migrate/20260812090019_create_ticketing_admission_use_reversals.rb app/models/ticketing test/models/ticketing/scanner_admission_schema_test.rb test/fixtures/ticketing_scanner_*.yml test/fixtures/ticketing_checkin_logs.yml test/fixtures/ticketing_admission_uses.yml
git commit -m "feat(scanner): add scanner admission schema"
```

The migration is intentionally split into one table per migration to follow
the repository database rule. The four listed fixture files are kept empty in
Task 1 because the package workflow test data is created dynamically; later
scanner API tasks can add stable fixtures once their service contracts exist.

## Task 2: Authenticate devices and authorize event assignments and zones

**Files:**
- Create: `app/services/ticketing/scanners/register_device.rb`
- Create: `app/services/ticketing/scanners/assign_to_event.rb`
- Create: `app/services/ticketing/scanners/rotate_token.rb`
- Create: `app/services/ticketing/scanners/authenticate.rb`
- Create: `app/services/ticketing/zones/authorize_admission.rb`
- Create: `app/controllers/concerns/ticketing/scanner_authenticated.rb`
- Create: `app/controllers/ticketing/scanner/auth_controller.rb`
- Create: `app/policies/ticketing/scanner_device_assignment_policy.rb`
- Create: `config/locales/ticketing/scanner.en.yml`
- Modify: `config/routes.rb`
- Modify: `app/models/ticketing/scanner_device.rb`
- Modify: `app/models/ticketing/scanner_device_assignment.rb`
- Modify: `app/models/organizations/organization.rb`
- Modify: `postman/Digis API_collection.json`
- Test: `test/services/ticketing/scanners/authenticate_test.rb`
- Test: `test/services/ticketing/zones/authorize_admission_test.rb`
- Test: `test/controllers/ticketing/scanner/auth_controller_test.rb`

- [x] **Step 1: RED — require device and operator authorization**

Cover active/suspended/revoked device, assignment window, primary/collaborator organization, scanner/manager/admin roles, token rotation, multiple-zone scope, wrong date/type zone, and empty mapping meaning no permission when zones are enabled.

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanners test/services/ticketing/zones test/controllers/ticketing/scanner/auth_controller_test.rb`

Expected: FAIL because authentication is missing.

- [x] **Step 3: GREEN — store token digests and authorize both principals**

Registration returns plaintext once; store a keyed digest and compare in constant time. Load one active event assignment and separately authorize the signed-in user through Pundit. Rotation invalidates the old token and audits. Zone authorization requires both product-access and assignment mappings; null zone is valid only when zones are disabled for that date/type. Controllers live under `Ticketing::Scanner`; the route follows the repository's current unversioned convention.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanners test/services/ticketing/zones test/controllers/ticketing/scanner`

Expected: PASS.

- [x] **Step 5: REFACTOR — share request authentication, not admission policy**

The concern may set the assignment/operator; it cannot decide credential or zone eligibility.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add app/services/ticketing/scanners app/services/ticketing/zones app/controllers/concerns/ticketing app/controllers/ticketing/scanner app/policies/ticketing config/routes.rb test/services/ticketing test/controllers/ticketing/scanner
git commit -m "feat(scanner): authenticate devices and assignments"
```

Task 2 uses the repository's current API convention: `POST /scanner/auth`
keeps the signed-in operator's JWT in `Authorization` and receives the
scanner credential in `X-Scanner-Token`. The scanner concern establishes the
authenticated device/assignment context for later scanner endpoints; it does
not authorize ticket eligibility. The current route is intentionally
unversioned because the repository's existing routes are unversioned; a future
versioned API mount may preserve this dual-principal contract without making
the device credential a user JWT.

## Task 3: Publish atomic full and delta synchronization feeds

This task consumes and maintains `ticketing_revocations`, `ticketing_credential_revocations`, and `ticketing_attendee_index_entries`; package-level suspension rows remain owned by the credential plan.

**Files:**
- Create: `app/services/ticketing/scanner_sync/build_snapshot.rb`
- Create: `app/services/ticketing/scanner_sync/build_delta.rb`
- Create: `app/services/ticketing/attendee_index/upsert.rb`
- Create: `app/services/ticketing/attendee_index/changes_since.rb`
- Create: `app/services/events/schedule/bump_version.rb`
- Create: `app/controllers/ticketing/scanner/event_sync_controller.rb`
- Create: `app/serializers/ticketing/scanner_sync_serializer.rb`
- Modify: `app/services/events/schedule/change.rb` and all schedule/access-policy writers so event cursor versions advance transactionally
- Modify: `app/services/ticketing/revocations/publish_generation.rb`, suspension projection, and attendee-index generation writers so revocation/index cursors advance transactionally
- Modify: `db/migrate/20260717010100_create_events_events.rb` and `db/structure.sql` with event-scoped feed versions
- Create: `test/fixtures/files/ticketing/scanner_sync_contract_v1.json`
- Test: `test/services/ticketing/scanner_sync/build_delta_test.rb`
- Test: `test/controllers/ticketing/scanner/event_sync_controller_test.rb`
- Test: `test/contracts/ticketing/scanner_sync_contract_test.rb`
- Test: schedule/access-policy writer tests covering event-date, access-zone, product-access, and zone-grant version bumps

- [x] **Step 1: RED — specify feed families, ordering, and privacy**

Contract cases include public keys, package/generation revocations, CID revocations, attendee tombstones/additions, schedule/zones, server use IDs, and reversal deltas. Assert revocations/tombstones precede additions and exclude answers, consent, ID documents, finance, resale, payout, and notes.

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync test/controllers/ticketing/scanner/event_sync_controller_test.rb test/contracts/ticketing/scanner_sync_contract_test.rb`

Expected: FAIL because feed builders are missing.

- [x] **Step 3: GREEN — validate cursors and build one response contract**

`BuildSnapshot` and `BuildDelta` lock the event while reading the event-scoped
versions and feed rows, then `ScannerSyncSerializer` emits one allowlisted
contract. The endpoint is `GET /scanner/events/:event_id/sync` with `mode=full`
or `mode=delta`; delta requests must provide all four typed cursors. Cursor
verification returns `scanner_cursor_ahead`. Download does not advance
acknowledgements; the scanner acknowledges only after its local atomic apply
commits. Correctness-critical projections are written in lifecycle
transactions, not asynchronously rebuilt.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync test/controllers/ticketing/scanner/event_sync_controller_test.rb test/contracts/ticketing/scanner_sync_contract_test.rb test/models/ticketing/scanner_admission_schema_test.rb`

Also run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/schedule/change_test.rb test/integration/events/event_dates_test.rb test/services/catalog/accesses/replace_test.rb test/services/catalog/zones/replace_grants_test.rb`

Expected: PASS.

- [x] **Step 5: REFACTOR — preserve one version vocabulary**

Use `revocations`, `attendee_index`, `schedule`, and `reversals` consistently
across DB, JSON, and local SQLite. Schedule-version writers use an atomic
counter update to avoid validation-driven N+1 queries during recurrence
materialization.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add \
  app/controllers/ticketing/scanner/event_sync_controller.rb app/models/catalog/product_access_zone.rb \
  app/models/events/access_zone.rb app/models/events/event.rb app/models/events/event_date.rb \
  app/models/ticketing/admission_use_reversal.rb app/models/ticketing/attendee_index_entry.rb \
  app/models/ticketing/credential_revocation.rb app/models/ticketing/revocation.rb \
  app/serializers/ticketing/scanner_sync_serializer.rb app/services/catalog/accesses/replace.rb \
  app/services/catalog/zones/replace_grants.rb app/services/events/schedule \
  app/services/ticketing/attendee_index app/services/ticketing/credential_claims/accept.rb \
  app/services/ticketing/credential_generations/replace.rb app/services/ticketing/credentials/activate.rb \
  app/services/ticketing/outbox_handlers/order_fulfilled.rb \
  app/services/ticketing/outbox_handlers/registration_issuance_ready.rb \
  app/services/ticketing/qr/verifier.rb app/services/ticketing/revocations/publish_generation.rb \
  app/services/ticketing/scanner_sync app/services/ticketing/suspensions/support.rb \
  config/locales/ticketing/scanner.en.yml config/routes.rb \
  db/migrate/20260717010100_create_events_events.rb db/structure.sql \
  postman/'Digis API_collection.json' \
  test/contracts/ticketing/scanner_sync_contract_test.rb \
  test/fixtures/files/ticketing/scanner_sync_contract_v1.json \
  test/integration/events/event_dates_test.rb test/services/catalog/accesses/replace_test.rb \
  test/services/catalog/zones/replace_grants_test.rb test/services/events/schedule/change_test.rb \
  test/services/ticketing/scanner_sync test/controllers/ticketing/scanner/event_sync_controller_test.rb
git commit -m "feat(scanner): publish synchronization deltas"
```

## Task 4: Consume admission slots atomically online

**Files:**
- Create: `app/services/ticketing/admissions/consume.rb`
- Create: `app/services/ticketing/admissions/usage_policy.rb`
- Create: `app/services/ticketing/checkins/record_attempt.rb`
- Create: `app/controllers/ticketing/scanner/verifications_controller.rb`
- Test: `test/services/ticketing/admissions/consume_test.rb`
- Test: `test/integration/ticketing/admission_concurrency_test.rb`
- Test: `test/controllers/ticketing/scanner/verifications_controller_test.rb`

- [x] **Step 1: RED — specify group, bounded, unlimited, date, and zone behavior**

```ruby
test "group scan consumes every slot atomically" do
  result = Ticketing::Admissions::Consume.call(
    claims: credential_claims(:valid_group_three),
    product_access: catalog_product_accesses(:friday_venue),
    assignment: ticketing_scanner_device_assignments(:main_gate),
    access_zone: events_access_zones(:main_gate),
    client_scan_id: SecureRandom.uuid, scanned_at: Time.current,
    lookup_via: "qr", identity_check: nil
  )
  assert result.success?
  assert_equal 3, result.value.admission_uses.count
end
```

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/admissions/consume_test.rb test/integration/ticketing/admission_concurrency_test.rb`

Expected: FAIL because consumption is missing.

- [x] **Step 3: GREEN — validate once, resolve signed slots, lock deterministically**

Call `Ticketing::Credentials::Validator`, resolve `(tid,slot_position)` and compare signed set to immutable package slots. Lock ticket/generation/CID/slots/access/uses. Count only unreversed uses; apply positive `usage_limit` or explicit null unlimited; allocate `MAX(usage_number)+1`. Insert one immutable check-in and all uses atomically. Existing `client_scan_id` returns stored result. A group with one ineligible slot consumes none.

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/admissions test/integration/ticketing/admission_concurrency_test.rb test/controllers/ticketing/scanner/verifications_controller_test.rb`

Expected: PASS with one winner in a two-connection single-use race.

- [x] **Step 5: REFACTOR — share locked usage calculation with reconciliation**

`UsagePolicy` receives already locked rows and performs no locking itself.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add app/services/ticketing/admissions app/services/ticketing/checkins app/controllers/ticketing/scanner test/services/ticketing/admissions test/integration/ticketing test/controllers/ticketing/scanner
git commit -m "feat(scanner): consume admission slots atomically"
```

## Task 5: Reconcile idempotent offline uploads

**Files:**
- Create: `app/services/ticketing/scanner_sync/process_upload.rb`
- Create: `app/services/ticketing/scanner_sync/reconcile_scan.rb`
- Create: `app/controllers/ticketing/scanner/scan_uploads_controller.rb`
- Modify: `app/models/ticketing/scan_upload.rb`, `app/models/ticketing/checkin_log.rb`, `app/services/ticketing/admissions/consume.rb`, and `app/services/ticketing/checkins/record_attempt.rb`
- Modify: `db/migrate/20260812090016_create_ticketing_scan_uploads.rb`, `db/structure.sql`, `config/routes.rb`, `config/locales/ticketing/scanner.en.yml`, and `postman/Digis API_collection.json`
- Test: `test/services/ticketing/scanner_sync/process_upload_test.rb`
- Test: `test/integration/ticketing/offline_scan_conflict_test.rb`
- Test: `test/controllers/ticketing/scanner/scan_uploads_controller_test.rb`

- [x] **Step 1: RED — test batch and nested idempotency plus stale conflicts**

Cover repeat upload ID, same scan ID across batches, interrupted batch, two offline scanners claiming one slot/access, stale generation, suspension/CID revocation, wrong zone, and empty heartbeat returning every feed family.

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync/process_upload_test.rb test/integration/ticketing/offline_scan_conflict_test.rb`

Observed: FAIL before schema/API setup because the original upload table lacked
`results_snapshot` and the integration requests lacked the required scanner
device identifier. Those failures established the missing GREEN contract.

- [x] **Step 3: GREEN — persist one response snapshot and reconcile authoritatively**

`ProcessUpload` locks the assignment and upload, bounds batches at 500 scans,
preloads prior `client_scan_id` results, reconciles new scans inside the same
transaction, builds the cursor delta, and stores the allowlisted response in
`results_snapshot` before returning success. Completed uploads return that
snapshot unchanged; bounded unique-conflict retries never loop indefinitely.

`ReconcileScan` calls the same validator/usage policy as online admission and records authoritative outcomes even when the device reported success. Return server use IDs before reversal rows.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync test/services/ticketing/admissions test/services/ticketing/scanners test/services/ticketing/zones test/models/ticketing/scanner_admission_schema_test.rb test/integration/ticketing/offline_scan_conflict_test.rb test/integration/ticketing/admission_concurrency_test.rb test/controllers/ticketing/scanner test/contracts/ticketing/scanner_sync_contract_test.rb`

Observed: PASS — 56 tests, 222 assertions, zero failures/errors.

- [x] **Step 5: REFACTOR — bound response and transaction memory**

Persist results before acknowledging; never mark client scans synchronized merely because the request reached the server. The snapshot excludes holder, consent, financial, and raw credential data, and completed snapshots are immutable through the model contract.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add app/services/ticketing/scanner_sync app/controllers/ticketing/scanner test/services/ticketing/scanner_sync test/integration/ticketing test/controllers/ticketing/scanner
git commit -m "feat(scanner): reconcile offline uploads"
```

## Task 6: Add PNR, phone, and audited online lookup

**Files:**
- Create: `app/services/ticketing/manual_lookup/base.rb`
- Create: `app/services/ticketing/manual_lookup/by_code.rb`
- Create: `app/services/ticketing/manual_lookup/by_phone.rb`
- Create: `app/services/ticketing/manual_lookup/online_search.rb`
- Create: `app/controllers/ticketing/scanner/lookups_controller.rb`
- Modify: `app/values/ticketing/credential_claims.rb`, `app/services/core/phone_identity/resolve_or_create.rb`, and `app/services/ticketing/attendee_index/upsert.rb`
- Modify: `config/routes.rb`, `config/locales/ticketing/scanner.en.yml`, and `postman/Digis API_collection.json`
- Test: `test/services/ticketing/manual_lookup/by_code_test.rb`
- Test: `test/services/ticketing/manual_lookup/by_phone_test.rb`
- Test: `test/services/ticketing/manual_lookup/online_search_test.rb`
- Test: `test/controllers/ticketing/scanner/lookups_controller_test.rb`
- Test: `test/contracts/ticketing/qr_manual_lookup_parity_test.rb`

- [x] **Step 1: RED — prove lookup is recovery, never bypass**

Require reason code, PNR checksum, canonical E.164 hashes, multiple-match disambiguation, trusted help-desk authorization/audit, and QR/PNR/phone outcome parity.

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/manual_lookup test/contracts/ticketing/qr_manual_lookup_parity_test.rb`

Observed: FAIL because the lookup services and shared index-to-claims constructor were missing.

- [x] **Step 3: GREEN — reconstruct `CredentialClaims` from active index rows**

PNR uses the exact checksummed indexed code; phone input is normalized to canonical Ethiopian E.164 before hashing and searches both holder and owner projections. Online identity search is restricted to trusted event manager/admin roles, rate-limited, audited without raw query/phone/PNR values, and returns bounded minimal disambiguation. Selected results call the shared index-to-claims constructor and then `Admissions::Consume`; lookup never authorizes by package ID alone.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/manual_lookup test/controllers/ticketing/scanner/lookups_controller_test.rb test/contracts/ticketing/qr_manual_lookup_parity_test.rb`

Observed: PASS — 12 tests, 55 assertions, zero failures/errors with `N_PLUS_ONE=1`.

- [x] **Step 5: REFACTOR — keep one index-to-claims constructor**

Code, phone, and online search selection share one index-to-claims constructor and the existing admission validator/consumer. The controller adds the event-scoped lookups contract, locales, and Postman example.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add app/services/ticketing/manual_lookup \
  app/controllers/ticketing/scanner/lookups_controller.rb \
  app/services/core/phone_identity/resolve_or_create.rb \
  app/services/ticketing/attendee_index/upsert.rb \
  app/values/ticketing/credential_claims.rb \
  test/services/ticketing/manual_lookup \
  test/controllers/ticketing/scanner/lookups_controller_test.rb \
  test/contracts/ticketing/qr_manual_lookup_parity_test.rb \
  config/routes.rb config/locales/ticketing/scanner.en.yml \
  "postman/Digis API_collection.json"
git commit -m "feat(scanner): add credential manual lookup"
```

## Task 7: Add ID mismatch override and append-only use reversal

**Files:**
- Create: `app/lib/ticketing/idempotency_uuid.rb`
- Create: `app/services/ticketing/checkins/record_identity_mismatch.rb`
- Create: `app/services/ticketing/checkins/override_identity_mismatch.rb`
- Create: `app/services/ticketing/admission_use_reversals/create.rb`
- Modify: `app/services/ticketing/admissions/consume.rb`
- Modify: `app/services/ticketing/checkins/record_attempt.rb`
- Create: `app/controllers/ticketing/checkin_identity_overrides_controller.rb`
- Create: `app/controllers/ticketing/admission_use_reversals_controller.rb`
- Modify: `config/routes.rb`, `config/locales/ticketing/scanner.en.yml`, and `postman/Digis API_collection.json`
- Test: `test/services/ticketing/checkins/override_identity_mismatch_test.rb`
- Test: `test/services/ticketing/admission_use_reversals/create_test.rb`
- Test: `test/integration/ticketing/admission_reversal_concurrency_test.rb`
- Test: `test/integration/ticketing/checkin_corrections_test.rb`

- [x] **Step 1: RED — specify immutable correction semantics**

Cover QR mode, ID match, mismatch/no use, offline override rejection, concurrent manager override, revalidation after change, manager/reason, one reversal per use, whole-group reversal, idempotent/conflicting retry, and next ordinal after reversal.

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/checkins/override_identity_mismatch_test.rb test/services/ticketing/admission_use_reversals/create_test.rb`

Observed: FAIL because the correction commands were missing; after removing only
the exact stale orphan rows left by the earlier non-transactional test attempt,
the suite reached the expected missing-constant failures.

- [x] **Step 3: GREEN — append linked attempts and complete reversal groups**

Override locks the mismatch/slot scopes, authorizes manager, revalidates, appends one linked success, and creates uses; it never edits mismatch. Reversal locks original check-in and all uses, creates one reversal per use with shared UUID/version, increments event reversal version once, and records audit/outbox. Original rows are immutable.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/checkins/override_identity_mismatch_test.rb test/services/ticketing/admission_use_reversals/create_test.rb test/integration/ticketing/admission_reversal_concurrency_test.rb test/integration/ticketing/checkin_corrections_test.rb`

Observed: PASS — 15 tests, 120 assertions, zero failures/errors.

- [x] **Step 5: REFACTOR — centralize active-use counting**

`Ticketing::Admissions::UsagePolicy` remains the single active-use and next-
ordinal implementation. The reversal command locks the same use scope and
leaves historical ordinals untouched, so later admission uses allocate the
next number from all history while eligibility counts only unreversed rows.

Adjacent regression coverage also passed with `N_PLUS_ONE=1`: 35 tests and
150 assertions across admission consumption, scanner sync/upload, controller,
schema, and concurrency tests.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add \
  app/lib/ticketing/idempotency_uuid.rb \
  app/services/ticketing/admissions/consume.rb \
  app/services/ticketing/checkins/record_attempt.rb \
  app/services/ticketing/checkins/record_identity_mismatch.rb \
  app/services/ticketing/checkins/override_identity_mismatch.rb \
  app/services/ticketing/admission_use_reversals/create.rb \
  app/controllers/ticketing/checkin_identity_overrides_controller.rb \
  app/controllers/ticketing/admission_use_reversals_controller.rb \
  test/services/ticketing/checkins/override_identity_mismatch_test.rb \
  test/services/ticketing/admission_use_reversals/create_test.rb \
  test/integration/ticketing/admission_reversal_concurrency_test.rb \
  test/integration/ticketing/checkin_corrections_test.rb \
  config/routes.rb config/locales/ticketing/scanner.en.yml \
  "postman/Digis API_collection.json" \
  docs/superpowers/plans/2026-07-17-scanner-offline-admission-implementation.md \
  docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md
git commit -m "feat(scanner): add admission corrections"
```

## Task 8: Freeze native scanner contract and scale gates

**Files:**
- Create: `docs/scanner/credential-validation-contract.md`
- Create: `test/contracts/ticketing/native_scanner_contract_test.rb`
- Create: `test/performance/ticketing/scanner_sync_performance_test.rb`
- Modify: `test/fixtures/files/ticketing/credential_contract_v1.json`
- Modify: `test/fixtures/files/ticketing/scanner_sync_contract_v1.json`

- [x] **Step 1: RED — execute complete decision corpus**

Include signature/event/access/window/zone/dead/suspended/generation/CID/claims/identity/use cases, stale delegation/transfer/resale/suspension, crash-before-cursor-commit replay, and disconnected conflict.

The RED test initially failed on the missing versioned decision, vocabulary,
replay, and performance metadata. The corpus now keeps credential decisions in
`credential_contract_v1.json` and synchronization/replay semantics in
`scanner_sync_contract_v1.json`.

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/contracts/ticketing/native_scanner_contract_test.rb test/performance/ticketing/scanner_sync_performance_test.rb`

Observed: the focused run reached the expected missing-contract-key failures
after the database access prerequisite was available.

- [x] **Step 3: GREEN — document local SQLite and atomic apply**

Define local revocations, CID revocations, scans, uses, reversals, zones/mappings, attendee lookup, and scanner state. Apply server use IDs, revocations, tombstones, additions, reversals, policies, then cursors in one SQLite transaction. Store public keys only. Benchmark production-shaped 50K index/snapshot and 500-scan upload within explicit test constants.

The Rails repository does not contain a native client or a bundled `sqlite3`
runtime. Therefore this task freezes the cross-language JSON decision table,
documents the required native SQLite transaction, and verifies Rails-side
payload serialization. The real native-client SQLite run remains an external
acceptance prerequisite.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/contracts/ticketing test/performance/ticketing/scanner_sync_performance_test.rb`

Result: PASS in Rails — 13 tests, 173 assertions, zero failures, zero errors.
The selected Swift/Kotlin/Flutter client is not present in this repository and
remains unverified here.

- [x] **Step 5: REFACTOR — delete divergent native/reference algorithms**

No divergent native/reference algorithm was added. The JSON fixtures and
decision table remain the sole cross-language authority.

- [x] **Step 6: Commit** — merged into `main`

```bash
git add docs/scanner test/contracts/ticketing test/performance/ticketing test/fixtures/files/ticketing
git commit -m "test(scanner): freeze offline contract"
```

## Acceptance gate

The Rails-side Task 8 gate is focused-verified. The native-client rows below
remain open until a Swift, Kotlin, or Flutter scanner is available to execute
the same fixtures against its real SQLite implementation.

- [x] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:test:prepare`.
- [x] Run scanner models/services/controllers under `test/models/ticketing`, `test/services/ticketing`, and `test/controllers/ticketing/scanner`.
- [x] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/contracts/ticketing test/integration/ticketing test/performance/ticketing/scanner_sync_performance_test.rb`.
- [x] Prove QR, PNR, phone, and online selection call one validator.
- [x] Prove group consume/reversal is atomic and uploads are idempotent at batch and scan levels.
- [x] Prove current scanners reject revoked/dead/suspended/wrong-zone/exhausted credentials and stale behavior matches the documented limitation.
- [x] Prove scanner responses contain no answers, consent evidence, ID documents, finance, resale, payout, or notes.
- [x] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test` with `N_PLUS_ONE=1`.

- [ ] Native Swift/Kotlin/Flutter SQLite fixture acceptance — remains external
  because no native scanner client exists in this repository.

Accept only when Rails and native clients pass identical fixtures and cursor application is atomic.
