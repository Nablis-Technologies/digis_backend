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

- [ ] **Step 6: Commit**

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
- Modify: `config/routes.rb`
- Test: `test/services/ticketing/scanners/authenticate_test.rb`
- Test: `test/services/ticketing/zones/authorize_admission_test.rb`
- Test: `test/controllers/ticketing/scanner/auth_controller_test.rb`

- [ ] **Step 1: RED — require device and operator authorization**

Cover active/suspended/revoked device, assignment window, primary/collaborator organization, scanner/manager/admin roles, token rotation, multiple-zone scope, wrong date/type zone, and empty mapping meaning no permission when zones are enabled.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanners test/services/ticketing/zones test/controllers/ticketing/scanner/auth_controller_test.rb`

Expected: FAIL because authentication is missing.

- [ ] **Step 3: GREEN — store token digests and authorize both principals**

Registration returns plaintext once; store a keyed digest and compare in constant time. Load one active event assignment and separately authorize the signed-in user through Pundit. Rotation invalidates the old token and audits. Zone authorization requires both product-access and assignment mappings; null zone is valid only when zones are disabled for that date/type. Controllers live under `Ticketing::Scanner`; `/api/v1` remains only the route path.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanners test/services/ticketing/zones test/controllers/ticketing/scanner`

Expected: PASS.

- [ ] **Step 5: REFACTOR — share request authentication, not admission policy**

The concern may set the assignment/operator; it cannot decide credential or zone eligibility.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/scanners app/services/ticketing/zones app/controllers/concerns/ticketing app/controllers/ticketing/scanner app/policies/ticketing config/routes.rb test/services/ticketing test/controllers/ticketing/scanner
git commit -m "feat(scanner): authenticate devices and assignments"
```

## Task 3: Publish atomic full and delta synchronization feeds

This task consumes and maintains `ticketing_revocations`, `ticketing_credential_revocations`, and `ticketing_attendee_index_entries`; package-level suspension rows remain owned by the credential plan.

**Files:**
- Create: `app/services/ticketing/scanner_sync/build_snapshot.rb`
- Create: `app/services/ticketing/scanner_sync/build_delta.rb`
- Create: `app/services/ticketing/attendee_index/upsert.rb`
- Create: `app/services/ticketing/attendee_index/changes_since.rb`
- Create: `app/controllers/ticketing/scanner/event_sync_controller.rb`
- Create: `app/serializers/ticketing/scanner_sync_serializer.rb`
- Create: `test/fixtures/files/ticketing/scanner_sync_contract_v1.json`
- Test: `test/services/ticketing/scanner_sync/build_delta_test.rb`
- Test: `test/controllers/ticketing/scanner/event_sync_controller_test.rb`
- Test: `test/contracts/ticketing/scanner_sync_contract_test.rb`

- [ ] **Step 1: RED — specify feed families, ordering, and privacy**

Contract cases include public keys, package/generation revocations, CID revocations, attendee tombstones/additions, schedule/zones, server use IDs, and reversal deltas. Assert revocations/tombstones precede additions and exclude answers, consent, ID documents, finance, resale, payout, and notes.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync test/controllers/ticketing/scanner/event_sync_controller_test.rb test/contracts/ticketing/scanner_sync_contract_test.rb`

Expected: FAIL because feed builders are missing.

- [ ] **Step 3: GREEN — validate cursors and build one response contract**

```ruby
module Ticketing
  module ScannerSync
    class BuildDelta < Core::BaseService
      def initialize(assignment:, cursors:)
        @assignment, @cursors = assignment, cursors.transform_keys(&:to_sym)
      end

      def call
        event = @assignment.event
        verification = verify_cursors(event)
        return verification if verification.failure?
        success(
          versions: current_versions(event), signing_keys: Ticketing::Qr::Verifier.public_keys,
          package_revocations: Revocations::ChangesSince.call(event:, since: @cursors.fetch(:revocations)).value,
          credential_revocations: CredentialRevocations::ChangesSince.call(event:, since: @cursors.fetch(:revocations)).value,
          attendee_index: AttendeeIndex::ChangesSince.call(event:, since: @cursors.fetch(:attendee_index)).value,
          schedule: SchedulePolicies::ChangesSince.call(event:, since: @cursors.fetch(:schedule)).value,
          admission_use_reversals: AdmissionUseReversals::ChangesSince.call(event:, since: @cursors.fetch(:reversals)).value
        )
      end
    end
  end
end
```

Cursor verification returns typed `scanner_cursor_ahead` errors. Download does not advance acknowledgements; the scanner acknowledges only after its local atomic apply commits. Correctness-critical projections are written in lifecycle transactions, not asynchronously rebuilt.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync test/controllers/ticketing/scanner/event_sync_controller_test.rb test/contracts/ticketing/scanner_sync_contract_test.rb`

Expected: PASS.

- [ ] **Step 5: REFACTOR — preserve one version vocabulary**

Use `revocations`, `attendee_index`, `schedule`, and `reversals` consistently across DB, JSON, and local SQLite.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/scanner_sync app/services/ticketing/attendee_index app/controllers/ticketing/scanner app/serializers/ticketing test/services/ticketing/scanner_sync test/controllers/ticketing/scanner test/contracts/ticketing test/fixtures/files/ticketing
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

- [ ] **Step 1: RED — specify group, bounded, unlimited, date, and zone behavior**

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

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/admissions/consume_test.rb test/integration/ticketing/admission_concurrency_test.rb`

Expected: FAIL because consumption is missing.

- [ ] **Step 3: GREEN — validate once, resolve signed slots, lock deterministically**

Call `Ticketing::Credentials::Validator`, resolve `(tid,slot_position)` and compare signed set to immutable package slots. Lock ticket/generation/CID/slots/access/uses. Count only unreversed uses; apply positive `usage_limit` or explicit null unlimited; allocate `MAX(usage_number)+1`. Insert one immutable check-in and all uses atomically. Existing `client_scan_id` returns stored result. A group with one ineligible slot consumes none.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/admissions test/integration/ticketing/admission_concurrency_test.rb test/controllers/ticketing/scanner/verifications_controller_test.rb`

Expected: PASS with one winner in a two-connection single-use race.

- [ ] **Step 5: REFACTOR — share locked usage calculation with reconciliation**

`UsagePolicy` receives already locked rows and performs no locking itself.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/admissions app/services/ticketing/checkins app/controllers/ticketing/scanner test/services/ticketing/admissions test/integration/ticketing test/controllers/ticketing/scanner
git commit -m "feat(scanner): consume admission slots atomically"
```

## Task 5: Reconcile idempotent offline uploads

**Files:**
- Create: `app/services/ticketing/scanner_sync/process_upload.rb`
- Create: `app/services/ticketing/scanner_sync/reconcile_scan.rb`
- Create: `app/controllers/ticketing/scanner/scan_uploads_controller.rb`
- Test: `test/services/ticketing/scanner_sync/process_upload_test.rb`
- Test: `test/integration/ticketing/offline_scan_conflict_test.rb`
- Test: `test/controllers/ticketing/scanner/scan_uploads_controller_test.rb`

- [ ] **Step 1: RED — test batch and nested idempotency plus stale conflicts**

Cover repeat upload ID, same scan ID across batches, interrupted batch, two offline scanners claiming one slot/access, stale generation, suspension/CID revocation, wrong zone, and empty heartbeat returning every feed family.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync/process_upload_test.rb test/integration/ticketing/offline_scan_conflict_test.rb`

Expected: FAIL because upload processing is missing.

- [ ] **Step 3: GREEN — persist one response snapshot and reconcile authoritatively**

```ruby
module Ticketing
  module ScannerSync
    class ProcessUpload < Core::BaseService
      def initialize(assignment:, client_upload_id:, scans:, cursors:)
        @assignment, @client_upload_id, @scans, @cursors = assignment, client_upload_id, scans, cursors
      end

      def call
        return failure Core::BusinessError.new(
          "Upload exceeds 500 scans", code: "scanner_batch_too_large", status: :payload_too_large
        ) if @scans.length > 500
        ScanUpload.transaction do
          upload = ScanUpload.lock.find_or_create_by!(
            scanner_device_assignment: @assignment, client_upload_id: @client_upload_id
          )
          return success(upload.results_snapshot) if upload.completed_at?
          results = @scans.map do |attributes|
            prior = CheckinLog.find_by(client_scan_id: attributes.fetch(:client_scan_id))
            prior ? prior.serialized_result : ReconcileScan.call(
              assignment: @assignment, upload:, attributes:
            ).value
          end
          snapshot = { results:, sync: BuildDelta.call(assignment: @assignment, cursors: @cursors).value }
          upload.update!(completed_at: Time.current, results_snapshot: snapshot)
          success(snapshot)
        end
      rescue ActiveRecord::RecordNotUnique
        retry
      end
    end
  end
end
```

`ReconcileScan` calls the same validator/usage policy as online admission and records authoritative outcomes even when the device reported success. Return server use IDs before reversal rows.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/scanner_sync test/integration/ticketing/offline_scan_conflict_test.rb test/controllers/ticketing/scanner/scan_uploads_controller_test.rb`

Expected: PASS.

- [ ] **Step 5: REFACTOR — bound response and transaction memory**

Persist results before acknowledging; never mark client scans synchronized merely because the request reached the server.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/scanner_sync app/controllers/ticketing/scanner test/services/ticketing/scanner_sync test/integration/ticketing test/controllers/ticketing/scanner
git commit -m "feat(scanner): reconcile offline uploads"
```

## Task 6: Add PNR, phone, and audited online lookup

**Files:**
- Create: `app/services/ticketing/manual_lookup/by_code.rb`
- Create: `app/services/ticketing/manual_lookup/by_phone.rb`
- Create: `app/services/ticketing/manual_lookup/online_search.rb`
- Create: `app/controllers/ticketing/scanner/lookups_controller.rb`
- Test: `test/services/ticketing/manual_lookup/by_code_test.rb`
- Test: `test/services/ticketing/manual_lookup/by_phone_test.rb`
- Test: `test/contracts/ticketing/qr_manual_lookup_parity_test.rb`

- [ ] **Step 1: RED — prove lookup is recovery, never bypass**

Require reason code, PNR checksum, canonical E.164 hashes, multiple-match disambiguation, trusted help-desk authorization/audit, and QR/PNR/phone outcome parity.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/manual_lookup test/contracts/ticketing/qr_manual_lookup_parity_test.rb`

Expected: FAIL because lookup services are missing.

- [ ] **Step 3: GREEN — reconstruct `CredentialClaims` from active index rows**

PNR uses exact indexed code; phone hashes normalized E.164 and searches holder plus owner hash. Online name/phone search is rate-limited, audited, and returns minimal disambiguation. Selected results call `CredentialClaims.from_index_entry` then `Admissions::Consume`; never authorize by package ID alone.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/manual_lookup test/contracts/ticketing/qr_manual_lookup_parity_test.rb`

Expected: PASS.

- [ ] **Step 5: REFACTOR — keep one index-to-claims constructor**

Code, phone, and name paths share the same constructor and validator.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/manual_lookup app/controllers/ticketing/scanner test/services/ticketing/manual_lookup test/contracts/ticketing
git commit -m "feat(scanner): add credential manual lookup"
```

## Task 7: Add ID mismatch override and append-only use reversal

**Files:**
- Create: `app/services/ticketing/checkins/record_identity_mismatch.rb`
- Create: `app/services/ticketing/checkins/override_identity_mismatch.rb`
- Create: `app/services/ticketing/admission_use_reversals/create.rb`
- Create: `app/controllers/ticketing/checkin_identity_overrides_controller.rb`
- Create: `app/controllers/ticketing/admission_use_reversals_controller.rb`
- Test: `test/services/ticketing/checkins/override_identity_mismatch_test.rb`
- Test: `test/services/ticketing/admission_use_reversals/create_test.rb`
- Test: `test/integration/ticketing/admission_reversal_concurrency_test.rb`

- [ ] **Step 1: RED — specify immutable correction semantics**

Cover QR mode, ID match, mismatch/no use, offline override rejection, concurrent manager override, revalidation after change, manager/reason, one reversal per use, whole-group reversal, idempotent/conflicting retry, and next ordinal after reversal.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/checkins test/services/ticketing/admission_use_reversals test/integration/ticketing/admission_reversal_concurrency_test.rb`

Expected: FAIL because correction commands are missing.

- [ ] **Step 3: GREEN — append linked attempts and complete reversal groups**

Override locks the mismatch/slot scopes, authorizes manager, revalidates, appends one linked success, and creates uses; it never edits mismatch. Reversal locks original check-in and all uses, creates one reversal per use with shared UUID/version, increments event reversal version once, and records audit/outbox. Original rows are immutable.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/checkins test/services/ticketing/admission_use_reversals test/integration/ticketing/admission_reversal_concurrency_test.rb`

Expected: PASS.

- [ ] **Step 5: REFACTOR — centralize active-use counting**

Count unreversed rows for eligibility; compute next ordinal from all history.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/checkins app/services/ticketing/admission_use_reversals app/controllers/ticketing test/services/ticketing test/integration/ticketing
git commit -m "feat(scanner): add admission corrections"
```

## Task 8: Freeze native scanner contract and scale gates

**Files:**
- Create: `docs/scanner/credential-validation-contract.md`
- Create: `test/contracts/ticketing/native_scanner_contract_test.rb`
- Create: `test/performance/ticketing/scanner_sync_performance_test.rb`
- Modify: `test/fixtures/files/ticketing/credential_contract_v1.json`
- Modify: `test/fixtures/files/ticketing/scanner_sync_contract_v1.json`

- [ ] **Step 1: RED — execute complete decision corpus**

Include signature/event/access/window/zone/dead/suspended/generation/CID/claims/identity/use cases, stale delegation/transfer/resale/suspension, crash-before-cursor-commit replay, and disconnected conflict.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/contracts/ticketing/native_scanner_contract_test.rb test/performance/ticketing/scanner_sync_performance_test.rb`

Expected: FAIL until every contract outcome and performance budget exists.

- [ ] **Step 3: GREEN — document local SQLite and atomic apply**

Define local revocations, CID revocations, scans, uses, reversals, zones/mappings, attendee lookup, and scanner state. Apply server use IDs, revocations, tombstones, additions, reversals, policies, then cursors in one SQLite transaction. Store public keys only. Benchmark production-shaped 50K index/snapshot and 500-scan upload within explicit test constants.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/contracts/ticketing test/performance/ticketing/scanner_sync_performance_test.rb`

Expected: PASS in Rails and the selected Swift/Kotlin/Flutter client.

- [ ] **Step 5: REFACTOR — delete divergent native/reference algorithms**

The JSON fixtures and decision table remain the sole cross-language authority.

- [ ] **Step 6: Commit**

```bash
git add docs/scanner test/contracts/ticketing test/performance/ticketing test/fixtures/files/ticketing
git commit -m "test(scanner): freeze offline contract"
```

## Acceptance gate

- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:test:prepare`.
- [ ] Run scanner models/services/controllers under `test/models/ticketing`, `test/services/ticketing`, and `test/controllers/ticketing/scanner`.
- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/contracts/ticketing test/integration/ticketing test/performance/ticketing/scanner_sync_performance_test.rb`.
- [ ] Prove QR, PNR, phone, and online selection call one validator.
- [ ] Prove group consume/reversal is atomic and uploads are idempotent at batch and scan levels.
- [ ] Prove current scanners reject revoked/dead/suspended/wrong-zone/exhausted credentials and stale behavior matches the documented limitation.
- [ ] Prove scanner responses contain no answers, consent evidence, ID documents, finance, resale, payout, or notes.
- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test`.

Accept only when Rails and native clients pass identical fixtures and cursor application is atomic.
