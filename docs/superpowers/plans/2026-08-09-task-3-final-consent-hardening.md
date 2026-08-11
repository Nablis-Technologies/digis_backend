# Task 3 Final Consent Hardening Implementation Plan

**Goal:** Make initial registration submission require exact required buyer consent while enforcing the remaining consent evidence and version-lifecycle boundaries at the database layer.

**Architecture:** `Ticketing::Registrations::Submit` remains the aggregate transaction owner. `Ticketing::Consent::BuildRequirements` builds all requirements, validates a one-to-one explicit buyer-acceptance command for every required buyer requirement, and delegates acceptance before the transaction can return a commercial next action. PostgreSQL triggers/checks protect evidence, lifecycle metadata, and the pre-issuance slot boundary against bypasses.

### Task 1: Submission Buyer Gate
- [ ] Add failing submission tests for missing/duplicate/unknown/slot-scoped/malformed buyer acceptance rollback and valid required buyer acceptance success.
- [ ] Add failing tests for missing/invalid nested `request_uuid` and idempotency key.
- [ ] Make `RegistrationSubmission` preserve explicit acceptance UUID/key input; have `BuildRequirements` require exactly one matching required buyer acceptance and call `Accept` with it.
- [ ] Run the focused registration and consent suites after every minimal change.

### Task 2: Database Guardrails
- [ ] Add failing model/direct-SQL tests for unverified consent signer, draft-to-published metadata, and pre-issuance `admission_slot_id`.
- [ ] Edit original migrations only: reject unverified signer inserts, require consistent published metadata, and prohibit non-null pre-issuance slot IDs.
- [ ] Regenerate `db/structure.sql` from a clean migrated database and load the test schema.

### Task 3: Verification
- [ ] Run focused consent/registration suites with `N_PLUS_ONE=1`, then the full suite.
- [ ] Run RuboCop, Zeitwerk, Brakeman, migration status, Postman JSON parse, and `git diff --check`.

### Task 4: Public Consent Discovery
- [ ] Add a public event-slug and ticket-type scoped endpoint that returns only active, current, applicable published consent document versions.
- [ ] Serialize only the exact version ID, document version number, title, body, SHA-256, required flag, and acceptance scope; do not expose organizer, signer, registration, or evidence fields.
- [ ] Cover event-wide and ticket-type-scoped documents, inactive and unrelated exclusions, and non-public event access with integration tests.

### Task 5: Credential Requirements Handoff
- [ ] Publish one idempotent `Core::Outbox` event after a personal withdrawal or consent reassignment with only registration ID, complete/pending status, and affected coordinates.
- [ ] Keep consent content, evidence, signer identity, credential state, QR, and PNR data outside the payload.
- [ ] Cover idempotency and payload privacy in the withdrawal and reassignment service tests.
