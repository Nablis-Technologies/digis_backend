# Ticket Packages and Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build commercial ticket packages, immutable admission slots, replaceable QR/PNR credential generations, delegation, recipient claims, transfers, and reversible suspensions.

**Architecture:** A ticket is the commercial package and owns fixed admission slots. `Ticketing::CredentialGenerations::Replace` is the only generation transition seam: one group credential or one individual credential per slot, never both. QR and PNR resolve immutable `Ticketing::CredentialClaims` and call one validator; commands inherit `Core::BaseService`, controllers are thin, and the existing transactional outbox handles post-commit delivery.

**Tech Stack:** Rails 8.1 API-only, Ruby 3.4, PostgreSQL UUIDs/check constraints/partial indexes/deferred triggers/advisory locks, Pundit, ActiveModelSerializers, Solid Queue, Ed25519, Minitest fixtures.

---

**Authoritative specifications:**

- `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`
- `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`

**Prerequisite:** Complete `docs/superpowers/plans/2026-07-17-event-platform-core-foundation.md`. Every expected rejection returns `failure Core::BusinessError.new(...)`; use the inherited `success`/`failure` helpers. Reuse `Core::IdempotencyKey`, `Core::Database::AdvisoryLock`, `Core::Audit::Record`, and `Core::Outbox::Publish`.

**Canonical lock order:** ticket, active generation, admission slots by position, current-access uses by `(product_access_id, admission_slot_id)`, package revocation, credential revocations, attendee-index rows. QR/PNR/index payloads never contain answers, consent evidence, ID documents, prices, fees, acquisition chains, payouts, or private notes.

## Task 1: Create package, slot, generation, credential, and projection schema

**Files:**
- Create: `db/migrate/20260812090001_create_ticketing_tickets.rb`
- Create: `db/migrate/20260812090002_create_ticketing_admission_slots.rb`
- Create: `db/migrate/20260812090003_create_ticketing_credential_generations.rb`
- Create: `db/migrate/20260812090004_create_ticketing_credentials.rb`
- Create: `db/migrate/20260812090005_create_ticketing_credential_claims.rb`
- Create: `db/migrate/20260812090006_create_ticketing_revocations.rb`
- Create: `db/migrate/20260812090007_create_ticketing_credential_revocations.rb`
- Create: `db/migrate/20260812090008_create_ticketing_attendee_index_entries.rb`
- Create: `db/migrate/20260812090009_add_ticketing_package_credential_constraints.rb`
- Create: `app/models/ticketing/ticket.rb`
- Create: `app/models/ticketing/admission_slot.rb`
- Create: `app/models/ticketing/credential_generation.rb`
- Create: `app/models/ticketing/credential.rb`
- Create: `app/models/ticketing/credential_claim.rb`
- Create: `app/models/ticketing/revocation.rb`
- Create: `app/models/ticketing/credential_revocation.rb`
- Create: `app/models/ticketing/attendee_index_entry.rb`
- Test: `test/models/ticketing/package_credential_schema_test.rb`

The schema test creates package records through the existing catalog and
registration setup so event-product, access, and parent foreign-key contracts
are exercised together; static fixtures are intentionally not added for these
records.

- [x] **Step 1: RED — write constraint tests**

```ruby
require "test_helper"

class Ticketing::PackageCredentialSchemaTest < ActiveSupport::TestCase
  test "one active generation exists per package" do
    generation = ticketing_credential_generations(:group_v1).dup
    generation.version = 2
    assert_raises(ActiveRecord::RecordNotUnique) { generation.save!(validate: false) }
  end

  test "one package credential exists per group generation" do
    generation = ticketing_credential_generations(:group_v1)
    duplicate = generation.credentials.first.dup
    duplicate.id = SecureRandom.uuid
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "earlier nullable references receive deferred foreign keys" do
    checks = [
      [Ticketing::RegistrationAnswer, :admission_slot_id],
      [Ticketing::RegistrationConsentRequirement, :admission_slot_id],
      [Ticketing::PurchaseLimitAllocation, :ticket_id]
    ]
    checks.each do |model, column|
      assert_raises(ActiveRecord::InvalidForeignKey) do
        model.transaction(requires_new: true) do
          record = model.first!
          model.where(id: record.id).update_all(column => SecureRandom.uuid)
          model.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
        end
      end
    end
  end

  test "credential type is business data" do
    assert_nil Ticketing::Credential.inheritance_column
  end
end
```

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/package_credential_schema_test.rb`

Expected: FAIL because the package tables and constraints do not exist.

- [x] **Step 3: GREEN — create exact database constraints**

```ruby
add_index :ticketing_tickets, %i[order_item_id unit_number], unique: true,
  where: "order_item_id IS NOT NULL"
add_index :ticketing_tickets, %i[registration_id unit_number], unique: true,
  where: "registration_id IS NOT NULL"
add_index :ticketing_admission_slots, %i[ticket_id position], unique: true
add_index :ticketing_credential_generations, %i[ticket_id version], unique: true
add_index :ticketing_credential_generations, :ticket_id, unique: true,
  where: "status = 'active'", name: "idx_one_active_generation_per_ticket"
add_index :ticketing_credentials, %i[event_id lookup_code], unique: true,
  where: "lookup_code IS NOT NULL"
add_index :ticketing_credentials, :credential_generation_id, unique: true,
  where: "type = 'package'", name: "idx_one_package_credential_per_generation"
add_index :ticketing_credentials, %i[credential_generation_id admission_slot_id], unique: true,
  where: "type = 'individual'", name: "idx_one_individual_credential_per_slot"
add_index :ticketing_credential_claims, :credential_id, unique: true
add_index :ticketing_credential_claims, :token_digest, unique: true

add_foreign_key :ticketing_registration_answers, :ticketing_admission_slots,
  column: :admission_slot_id, deferrable: :deferred
add_foreign_key :ticketing_registration_consent_requirements, :ticketing_admission_slots,
  column: :admission_slot_id, deferrable: :deferred
add_foreign_key :ticketing_purchase_limit_allocations, :ticketing_tickets,
  column: :ticket_id, deferrable: :deferred
```

Create every field and allowlist from Sections 8.5–8.9. Add checks for positive package size/version/position, acquisition field coupling, `entry_limit = cardinality(slot_positions)`, individual/package slot nullability, and active QR/PNR/time coupling. Add a deferred constraint trigger proving group generations contain one complete package credential and delegated generations contain exactly one individual credential per package slot with no mixed mode.

```ruby
module Ticketing
  class Credential < ApplicationRecord
    self.inheritance_column = nil
    belongs_to :ticket
    belongs_to :credential_generation
    belongs_to :admission_slot, optional: true
    belongs_to :event, class_name: "Events::Event"
    belongs_to :holder_user, class_name: "Core::User", optional: true
    encrypts :holder_name
  end
end
```

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate && PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/package_credential_schema_test.rb`

Expected: PASS.

- [x] **Step 5: REFACTOR — retain friendly model validation while proving DB enforcement**

Exercise every partial index/check with validations bypassed. Do not add callbacks that create credentials or mutate versions.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260812090001_create_ticketing_tickets.rb db/migrate/20260812090002_create_ticketing_admission_slots.rb db/migrate/20260812090003_create_ticketing_credential_generations.rb db/migrate/20260812090004_create_ticketing_credentials.rb db/migrate/20260812090005_create_ticketing_credential_claims.rb db/migrate/20260812090006_create_ticketing_revocations.rb db/migrate/20260812090007_create_ticketing_credential_revocations.rb db/migrate/20260812090008_create_ticketing_attendee_index_entries.rb db/migrate/20260812090009_add_ticketing_package_credential_constraints.rb app/models/ticketing test/models/ticketing/package_credential_schema_test.rb
git commit -m "feat(ticketing): add package credential schema"
```

## Task 2: Issue packages deterministically after fulfillment

**Files:**
- Create: `app/services/ticketing/packages/issue.rb`
- Create: `app/services/ticketing/credential_generations/create_initial_group.rb`
- Create: `app/services/ticketing/outbox_handlers/package_issued.rb`
- Create: `config/initializers/outbox_handlers.rb`
- Reuse: `app/models/core/outbox_event.rb`
- Reuse: `app/services/core/outbox/publish.rb`
- Reuse: `app/jobs/core/dispatch_outbox_event_job.rb`
- Test: `test/services/ticketing/packages/issue_test.rb`

- [ ] **Step 1: RED — specify retry-safe issuance**

```ruby
test "issues one package and complete slot set once" do
  item = orders_order_items(:paid_group_ticket)
  first = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1)
  second = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1)

  assert first.success?
  assert_equal first.value.id, second.value.id
  assert_equal [1, 2, 3], first.value.admission_slots.order(:position).pluck(:position)
  assert_equal "group", first.value.current_credential_generation.mode
  assert_equal 1, Core::OutboxEvent.where(
    aggregate_id: first.value.id, event_type: "ticketing.package_issued"
  ).count
end
```

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/packages/issue_test.rb`

Expected: FAIL because the issuance command is missing.

- [ ] **Step 3: GREEN — implement one issuance command**

```ruby
module Ticketing
  module Packages
    class Issue < Core::BaseService
      def initialize(order_item: nil, registration: nil, unit_number:)
        @order_item, @registration = order_item, registration
        @unit_number = Integer(unit_number)
      end

      def call
        outcome = nil
        Ticket.transaction do
          source = (@order_item || @registration).lock!
          existing = Ticket.find_by(source_key)
          return success(existing) if existing
          verification = verify_fulfillable(source)
          return verification if verification.failure?

          ticket = Ticket.create!(source.ticket_package_attributes(@unit_number).merge(
            credential_mode: "group", credential_version: 1, status: "active", issued_at: Time.current
          ))
          ticket.admissions_per_unit_snapshot.times do |offset|
            ticket.admission_slots.create!(position: offset + 1, assignment_status: "unassigned")
          end
          generation = CredentialGenerations::CreateInitialGroup.call(ticket:)
          if generation.failure?
            outcome = failure(generation.error)
            raise ActiveRecord::Rollback
          end
          publication = Core::Outbox::Publish.call(
            topic: "ticketing", event_type: "ticketing.package_issued", aggregate: ticket,
            payload: { ticket_id: ticket.id, version: 1 },
            idempotency_key: "ticketing.package-issued:#{ticket.id}:v1"
          )
          fail publication.error if publication.failure?
          outcome = success(ticket.reload)
        end
        outcome
      rescue ActiveRecord::RecordNotUnique
        success(Ticket.find_by!(source_key))
      end

      private

      def source_key
        @order_item ? { order_item_id: @order_item.id, unit_number: @unit_number } :
          { registration_id: @registration.id, unit_number: @unit_number }
      end

      def verify_fulfillable(source)
        return failure Core::BusinessError.new(
          "Unit number must be positive", code: "invalid_ticket_unit", status: :unprocessable_entity
        ) unless @unit_number.positive?
        return failure Core::BusinessError.new(
          "Fulfillment source is not eligible", code: "ticket_source_not_fulfillable", status: :conflict
        ) unless source.fulfillable_ticket_unit?(@unit_number)
        success
      end
    end
  end
end
```

Paid, zero-price, complimentary, and walk-up fulfillment call this command. `CreateInitialGroup` creates/signs/indexes one complete group credential only when personal requirements permit it. The registered outbox handler delivers after commit using the event idempotency key.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/packages/issue_test.rb test/services/orders`

Expected: PASS.

- [ ] **Step 5: REFACTOR — remove caller-specific package construction**

Keep financial, free, complimentary, and walk-up eligibility upstream; package construction remains identical.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/packages app/services/ticketing/credential_generations/create_initial_group.rb app/services/ticketing/outbox_handlers config/initializers/outbox_handlers.rb test/services/ticketing/packages
git commit -m "feat(ticketing): issue packages idempotently"
```

## Task 3: Centralize generation replacement

**Files:**
- Create: `app/services/ticketing/credential_generations/replace.rb`
- Create: `app/services/ticketing/revocations/publish_generation.rb`
- Create: `app/services/ticketing/attendee_index/apply_generation.rb`
- Test: `test/services/ticketing/credential_generations/replace_test.rb`
- Test: `test/integration/ticketing/credential_generation_concurrency_test.rb`

- [ ] **Step 1: RED — prove atomic all-or-nothing replacement**

```ruby
test "replaces group with one individual credential per slot" do
  ticket = ticketing_tickets(:unused_group_package)
  result = Ticketing::CredentialGenerations::Replace.call(
    ticket:, target_mode: "delegated", reason: "owner_delegated",
    assignments: { 1 => ticket.owner_user, 2 => nil, 3 => nil },
    idempotency_key: "delegate:#{ticket.id}:v2"
  )
  assert result.success?
  assert_equal 2, result.value.version
  assert_equal 3, result.value.credentials.count
  assert result.value.credentials.all?(&:individual?)
end
```

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/credential_generations/replace_test.rb`

Expected: FAIL because replacement is missing.

- [ ] **Step 3: GREEN — lock, revoke, replace, project, publish**

```ruby
module Ticketing
  module CredentialGenerations
    class Replace < Core::BaseService
      def initialize(ticket:, target_mode:, reason:, assignments:, idempotency_key:)
        @ticket, @target_mode, @reason = ticket, target_mode, reason
        @assignments, @idempotency_key = assignments, Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        Ticket.transaction do
          ticket = Ticket.lock.find(@ticket.id)
          prior = ticket.credential_generations.lock.find_by!(status: "active")
          slots = ticket.admission_slots.order(:position).lock.to_a
          lock_current_uses!(ticket, slots)
          verification = verify_transition(ticket, prior, slots)
          return verification if verification.failure?

          prior.update!(status: "revoked", revoked_at: Time.current, revocation_reason: @reason)
          generation = ticket.credential_generations.create!(
            version: prior.version + 1, mode: @target_mode, status: "active", activated_at: Time.current
          )
          create_complete_set!(ticket, generation, slots)
          Revocations::PublishGeneration.call(ticket:, through_version: prior.version, reason: @reason)
          AttendeeIndex::ApplyGeneration.call(old_generation: prior, new_generation: generation)
          ticket.update!(credential_mode: @target_mode, credential_version: generation.version,
            current_credential_generation: generation)
          publication = Core::Outbox::Publish.call(
            topic: "ticketing", event_type: "ticketing.credential_generation_replaced",
            aggregate: ticket, payload: { ticket_id: ticket.id, version: generation.version },
            idempotency_key: @idempotency_key.to_s
          )
          fail publication.error if publication.failure?
          success(generation)
        end
      rescue ActiveRecord::RecordNotUnique => error
        failure Core::BusinessError.new(
          "Credential generation changed concurrently", code: "credential_generation_conflict",
          status: :conflict, meta: { ticket_id: @ticket.id, cause: error.class.name }
        )
      end
    end
  end
end
```

Private methods enforce canonical locks, current-open-access use restrictions, cutoff/status/policy, exact group/delegated cardinality, personal-requirement states, never-reused CID/PNR, and revocation-before-index ordering. Failed transactions leave the prior generation active.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/credential_generations/replace_test.rb test/integration/ticketing/credential_generation_concurrency_test.rb`

Expected: PASS with one active complete generation under concurrent replacement.

- [ ] **Step 5: REFACTOR — route every generation transition through `Replace`**

Delegation cancellation, accepted transfer, resale success/failure, date-scoped refund, and postponement do not construct generations independently.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/credential_generations app/services/ticketing/revocations app/services/ticketing/attendee_index test/services/ticketing/credential_generations test/integration/ticketing
git commit -m "feat(ticketing): centralize credential replacement"
```

## Task 4: Sign QR claims, issue PNRs, and implement one validator

**Files:**
- Create: `app/services/ticketing/qr/signer.rb`
- Create: `app/services/ticketing/qr/verifier.rb`
- Create: `app/services/core/lookup_code_service.rb`
- Create: `app/value_objects/ticketing/credential_claims.rb`
- Create: `app/services/ticketing/credentials/validator.rb`
- Create: `test/fixtures/files/ticketing/credential_contract_v1.json`
- Test: `test/services/ticketing/qr/signer_test.rb`
- Test: `test/services/core/lookup_code_service_test.rb`
- Test: `test/contracts/ticketing/credential_contract_test.rb`

- [ ] **Step 1: RED — add crypto and language-neutral contract tests**

```ruby
test "QR and attendee-index claims have identical decisions" do
  contract_cases.each do |entry|
    qr_claims = Ticketing::Qr::Verifier.call(token: entry.fetch("token")).value
    index_claims = Ticketing::CredentialClaims.from_h(entry.fetch("claims"))
    context = contract_context(entry.fetch("context"))
    assert_equal entry.fetch("expected"), Ticketing::Credentials::Validator.call(claims: qr_claims, **context).value.to_s
    assert_equal entry.fetch("expected"), Ticketing::Credentials::Validator.call(claims: index_claims, **context).value.to_s
  end
end
```

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/qr test/services/core/lookup_code_service_test.rb test/contracts/ticketing/credential_contract_test.rb`

Expected: FAIL because claim signing and validation are missing.

- [ ] **Step 3: GREEN — implement canonical Ed25519 claims**

```ruby
module Ticketing
  CredentialClaims = Data.define(:kid, :cid, :tid, :eid, :mode, :slots, :entry_limit, :v, :accesses, :exp) do
    def self.from_h(value)
      normalized = value.deep_symbolize_keys.slice(*members)
      fail ArgumentError, "unexpected credential claims" unless normalized.keys.sort == members.sort
      new(**normalized)
    end

    def canonical_payload = to_h.transform_keys(&:to_s).sort.to_h.to_json
  end
end
```

Use deterministic canonical JSON and Ed25519. Private keys remain in credentials/KMS; scanners receive only keyed public keys. Validate exact claims `kid,cid,tid,eid,mode,slots,entry_limit,v,accesses,exp`, signature, expiry, unique positive slots, group/individual shape, event/access/window/zone, package death/suspension/version, CID revocation, and use eligibility. `LookupCodeService` issues seven random approved Crockford characters plus one Luhn-mod-alphabet digit and relies on `(event_id, lookup_code)` uniqueness with bounded retry.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/qr test/services/core/lookup_code_service_test.rb test/contracts/ticketing/credential_contract_test.rb`

Expected: PASS for known Ed25519, tamper, malformed claim, group, and individual cases.

- [ ] **Step 5: REFACTOR — freeze the scanner boundary**

Native scanner CI consumes this exact JSON corpus. Delete alternate QR/manual validation algorithms.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing/qr app/services/ticketing/credentials app/services/core/lookup_code_service.rb app/value_objects/ticketing test/services test/contracts test/fixtures/files/ticketing
git commit -m "feat(ticketing): sign and validate credential claims"
```

## Task 5: Implement delegation, claims, and package transfer

This task owns the append-only `ticketing_ticket_transfers` history. Delegation changes credential mode; transfer changes package ownership. Both replace generations, but they are distinct commercial operations.

**Files:**
- Create: `app/services/ticketing/delegations/activate.rb`
- Create: `app/services/ticketing/delegations/cancel.rb`
- Create: `app/services/ticketing/delegations/reassign_slot.rb`
- Create: `app/services/ticketing/credential_claims/invite.rb`
- Create: `app/services/ticketing/credential_claims/accept.rb`
- Create: `app/services/ticketing/transfers/initiate.rb`
- Create: `app/services/ticketing/transfers/accept.rb`
- Create: `app/jobs/ticketing/expire_credential_claims_job.rb`
- Create: `app/jobs/ticketing/expire_transfers_job.rb`
- Create: `app/controllers/ticketing/delegations_controller.rb`
- Create: `app/controllers/ticketing/credential_claims_controller.rb`
- Create: `app/controllers/ticketing/transfers_controller.rb`
- Create: `app/policies/ticketing/ticket_policy.rb`
- Create: `app/serializers/ticketing/credential_serializer.rb`
- Modify: `config/routes.rb`
- Test: `test/services/ticketing/delegations/activate_test.rb`
- Test: `test/services/ticketing/credential_claims/accept_test.rb`
- Test: `test/services/ticketing/transfers/accept_test.rb`
- Test: `test/controllers/ticketing/delegations_controller_test.rb`

- [ ] **Step 1: RED — specify lifecycle, recipient, cutoff, and privacy behavior**

Cover existing/shadow/unclaimed recipients, wrong user, expired/replayed token, personal waiver gating, concurrent accept/cancel, rescheduled cutoff, current-open use rejection, closed prior use preservation, and separately purchased add-ons staying with their owner.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/delegations test/services/ticketing/credential_claims test/services/ticketing/transfers test/controllers/ticketing/delegations_controller_test.rb`

Expected: FAIL because commands and controllers are missing.

- [ ] **Step 3: GREEN — implement commands and thin route-path-independent controllers**

```ruby
module Ticketing
  class DelegationsController < ApplicationController
    include Core::JsonResponse

    def create
      ticket = policy_scope(Ticketing::Ticket).find(params[:ticket_id])
      authorize ticket, :delegate?
      result = Ticketing::Delegations::Activate.call(
        ticket:, actor: current_user, assignments: params.require(:assignments).to_unsafe_h,
        idempotency_key: request.headers.fetch("Idempotency-Key")
      )
      return render_error(result.error, status: result.error.status) if result.failure?
      render_success(data: result.value, serializer: Ticketing::CredentialSerializer, status: :created)
    end
  end
end
```

The route remains `/api/v1/...`; Ruby namespaces remain `Ticketing`. Delegation/cancellation call `CredentialGenerations::Replace`; slot reassignment replaces one CID in delegated mode. Claim acceptance locks claim/credential/slot and issues QR/PNR/index only after recipient authentication and personal requirements. Transfer acceptance locks transfer/ticket/generation/slots, changes owner, and calls `Replace` targeting group mode.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/delegations test/services/ticketing/credential_claims test/services/ticketing/transfers test/controllers/ticketing`

Expected: PASS.

- [ ] **Step 5: REFACTOR — extract only proven recipient resolution**

When duplication appears across invitations, claims, and transfers, use one enumeration-safe `Core::Recipients::Resolve`; do not create a workflow engine.

- [ ] **Step 6: Commit**

```bash
git add app/services/ticketing app/jobs/ticketing app/controllers/ticketing app/policies/ticketing app/serializers/ticketing config/routes.rb test/services/ticketing test/controllers/ticketing
git commit -m "feat(ticketing): add delegation claims and transfers"
```

## Task 6: Add reversible suspension and terminal invalidation

**Files:**
- Create: `db/migrate/20260717210003_create_ticketing_ticket_suspensions.rb`
- Create: `app/models/ticketing/ticket_suspension.rb`
- Create: `app/services/ticketing/suspensions/open.rb`
- Create: `app/services/ticketing/suspensions/restore.rb`
- Create: `app/services/ticketing/suspensions/resolve.rb`
- Create: `app/jobs/ticketing/escalate_overdue_suspensions_job.rb`
- Create: `app/controllers/ticketing/suspensions_controller.rb`
- Test: `test/services/ticketing/suspensions/open_test.rb`
- Test: `test/services/ticketing/suspensions/restore_test.rb`
- Test: `test/integration/ticketing/suspension_concurrency_test.rb`

- [ ] **Step 1: RED — specify review without financial mutation**

Prove one active case, idempotent retry, scan/stream/transfer/delegation blocking, safe restore, free terminal revocation, paid cancellation staying suspended until refund success, and overdue escalation never auto-restoring.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing/suspensions test/integration/ticketing/suspension_concurrency_test.rb`

Expected: FAIL because suspension is missing.

- [ ] **Step 3: GREEN — create append-only review cases and revocation deltas**

```ruby
add_index :ticketing_ticket_suspensions, :ticket_id, unique: true,
  where: "status = 'active'", name: "idx_one_active_ticket_suspension"
add_index :ticketing_ticket_suspensions, :idempotency_key, unique: true
```

Commands lock ticket, suspension, and revocation in canonical order; bump event revocation version and write audit/outbox atomically. Restore is forbidden after refund/chargeback/death. Free tickets may become dead directly; paid organizer cancellation delegates to refunds and becomes dead only after refund success.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/ticketing test/integration/ticketing`

Expected: PASS.

- [ ] **Step 5: REFACTOR — keep revocation writers behind lifecycle commands**

Controllers and jobs cannot directly mutate package-dead/suspended projections.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260717210003_create_ticketing_ticket_suspensions.rb app/models/ticketing app/services/ticketing/suspensions app/jobs/ticketing app/controllers/ticketing test/services/ticketing/suspensions test/integration/ticketing
git commit -m "feat(ticketing): add reversible suspension"
```

## Acceptance gate

- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:test:prepare`.
- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing test/services/ticketing test/contracts/ticketing test/integration/ticketing test/controllers/ticketing`.
- [ ] Prove PostgreSQL rejects incomplete/mixed generations and all three deferred registration/package FKs.
- [ ] Prove duplicate issuance, replacement, claim acceptance, transfer, and suspension races with separate DB connections.
- [ ] Prove old QR/PNR values never reactivate after cancellation, transfer, or reassignment.
- [ ] Prove outbox delivery cannot observe uncommitted credentials and contains no sensitive payload.
- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test`.

Accept only with all tests passing, the native contract fixture mirrored, and no lifecycle transaction logic in controllers.
