# Marketing Campaigns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add organization-owned SMS or Email marketing campaigns with reusable audiences, organizer attestation, safe unsubscribe handling, configurable credit pricing, bounded delivery, and aggregate campaign credit holds.

**Architecture:** Campaigns owns campaign composition, audience/list snapshots, marketing suppression, lifecycle state, delivery records, and campaign analytics. It reuses the existing Messaging provider registry, outbox, bounded jobs, `Links::ShortLink`, and Credit/Billing ledger. One SMS credit is one provider-billed SMS segment; one Email credit is one recipient. A campaign creates one aggregate credit reservation at launch, and delivery pages allocate and settle slices of that hold without creating a second wallet.

**Tech Stack:** Ruby 3.4.2, Rails 8.1, PostgreSQL UUIDv7/check constraints/partial indexes, Active Record Encryption, Pundit, ActiveModelSerializers, Solid Queue, Active Storage, CSV, Minitest, Prosopite, `Core::JsonResponse`, `Core::IdempotencyKeyResolver`, `Core::Outbox`, `Messaging::Providers`, `Messaging::CreditAccounts`, and `Links::ShortLink`.

**Design spec:** `docs/superpowers/specs/2026-09-05-marketing-campaigns-design.md`

---

## Implementation rules

- Work only after the Messaging Credit/Billing plan is user-merged. Do not
  change transactional notification behavior to make campaigns fit.
- Use one table per migration. Campaign changes to the existing credit
  reservation/ledger contracts edit their original migrations/models, because
  this repository is pre-production and resets the preview database.
- Do not put raw phone numbers, email addresses, CSV content, message bodies,
  provider credentials, provider payloads, or unsubscribe tokens in jobs,
  outbox payloads, logs, or public serializers.
- Every mutating endpoint requires `Idempotency-Key`; the mark-read exception
  does not apply to campaigns, lists, imports, templates, suppression, or
  lifecycle commands.
- Use `assert_idempotent`/`assert_audit_idempotent`, not hand-written replay
  counters. Add integration coverage for missing keys and exact replay/conflict.
- Keep campaign delivery records separate from
  `Messaging::Notification`/`NotificationDelivery`; reuse the provider adapter
  and delivery-result seam, not the transactional inbox.
- Do not stage or commit automatically while executing this plan. Each commit
  step below is a user-owned checkpoint.

## Fixed product decisions

| Decision | Contract |
|---|---|
| Campaign channel | Immutable `sms` or `email`, selected at creation |
| SMS credit | One provider-billed physical segment; GSM-7/UCS-2 and concatenation determine quantity |
| Email credit | One recipient delivery |
| Audience sources | Registrants, ticket holders, past event-goers, organization subscribers, saved lists |
| Past-event basis | Organizer chooses issued/registered or checked-in |
| Combining sources | Union, deduplicated by normalized channel address |
| Imported-list consent | Organizer attestation at import and launch; suppression always wins |
| List ingestion | CSV and manual entry; reusable named lists; explicit append/replace |
| Launch approval | Authorized organizer reviews and explicitly launches; no per-campaign admin approval |
| Timing | Send now or schedule in captured campaign IANA timezone |
| Templates | Admin baselines plus organizer custom immutable versions and locale variants |
| Credit reservation | One aggregate campaign hold at launch; delivery pages allocate/settle slices |
| Unsubscribe | Verified provider inbound webhook plus tokenized public/email links |
| Stop behavior | Pause, then explicit abort; abort releases unallocated hold and is terminal |
| Links | Existing `Links::ShortLink` custom URL with UTM fields |
| Import limits | 5 MB, 10,000 rows/import, 50 saved lists/organization |
| Missing variable | `first_name` falls back to `there`; other contextual values fall back to empty text |
| Quote TTL | 15 minutes; expired or mismatched quote returns `campaign_quote_stale` |
| Unsubscribe token | 30-day `MessageVerifier` token, purpose `campaign_unsubscribe` |
| Phone normalization | Existing `Core::PhoneIdentity::ResolveOrCreate.normalize` |
| Unauthenticated ingress limits | 120 inbound webhook requests/provider/IP/minute; 30 unsubscribe requests/IP/minute |
| Volume policy | Admin-configurable per-organization/channel daily and monthly quotas, evaluated in the policy IANA timezone; counts launched quoted units conservatively |

## File map

### Existing credit/link contracts to modify

- Modify: `db/migrate/20260904090004_create_messaging_credit_reservations.rb`
  — allow the aggregate `Messaging::Campaign` source type and preserve the
  source/channel uniqueness boundary.
- Modify: `app/models/messaging/credit_reservation.rb` — expose aggregate
  campaign holds and preserve immutable reservation snapshots.
- Modify: `app/models/messaging/credit_ledger_entry.rb` — allow
  `Messaging::Campaign` and `Messaging::CampaignDelivery` references.
- Modify: `app/services/messaging/credit_accounts/command_support.rb` — add
  campaign-hold allocation/finalization helpers without routing an aggregate
  hold through per-recipient `Release`/`Refund`/`Consume`.
- Modify: `app/services/messaging/providers/adapter.rb` — add the campaign
  delivery method while retaining the transactional notification method.
- Modify: `app/models/links/short_link.rb` only if UTM normalization needs a
  shared validation; do not add `campaign` to `TARGET_TYPES`.
- Regenerate: `db/structure.sql` after migrations.

### Campaign persistence (one table per migration)

- Create: `db/migrate/20260906090001_create_messaging_campaign_templates.rb`
- Create: `db/migrate/20260906090002_create_messaging_campaign_template_versions.rb`
- Create: `db/migrate/20260906090003_create_messaging_campaign_contact_lists.rb`
- Create: `db/migrate/20260906090004_create_messaging_campaign_contact_list_entries.rb`
- Create: `db/migrate/20260906090005_create_messaging_campaign_contact_list_imports.rb`
- Create: `db/migrate/20260906090006_create_messaging_campaign_volume_policies.rb`
- Create: `db/migrate/20260906090007_create_messaging_campaign_suppressions.rb`
- Create: `db/migrate/20260906090008_create_messaging_campaign_inbound_events.rb`
- Create: `db/migrate/20260906090009_create_messaging_campaigns.rb`
- Create: `db/migrate/20260906090010_create_messaging_campaign_audience_snapshots.rb`
- Create: `db/migrate/20260906090011_create_messaging_campaign_recipients.rb`
- Create: `db/migrate/20260906090012_create_messaging_campaign_attestations.rb`
- Create: `db/migrate/20260906090013_create_messaging_campaign_deliveries.rb`
- Create: `db/migrate/20260906090014_create_messaging_campaign_credit_allocations.rb`
- Create: `db/migrate/20260906090015_create_messaging_campaign_links.rb`

### Campaign models

- Create: `app/models/messaging/campaign.rb`
- Create: `app/models/messaging/campaign_template.rb`
- Create: `app/models/messaging/campaign_template_version.rb`
- Create: `app/models/messaging/campaign_contact_list.rb`
- Create: `app/models/messaging/campaign_contact_list_entry.rb`
- Create: `app/models/messaging/campaign_contact_list_import.rb`
- Create: `app/models/messaging/campaign_audience_snapshot.rb`
- Create: `app/models/messaging/campaign_recipient.rb`
- Create: `app/models/messaging/campaign_attestation.rb`
- Create: `app/models/messaging/campaign_delivery.rb`
- Create: `app/models/messaging/campaign_credit_allocation.rb`
- Create: `app/models/messaging/campaign_link.rb`
- Create: `app/models/messaging/campaign_suppression.rb`
- Create: `app/models/messaging/campaign_volume_policy.rb`
- Create: `app/models/messaging/campaign_inbound_event.rb`

### Domain services and value objects

- Create: `app/services/messaging/campaigns/create.rb`
- Create: `app/services/messaging/campaigns/update.rb`
- Create: `app/services/messaging/campaigns/estimate.rb`
- Create: `app/services/messaging/campaigns/launch.rb`
- Create: `app/services/messaging/campaigns/pause.rb`
- Create: `app/services/messaging/campaigns/resume.rb`
- Create: `app/services/messaging/campaigns/cancel.rb`
- Create: `app/services/messaging/campaigns/abort.rb`
- Create: `app/services/messaging/campaigns/audience/resolve.rb`
- Create: `app/services/messaging/campaigns/audience/snapshot.rb`
- Create: `app/services/messaging/campaigns/contact_lists/create.rb`
- Create: `app/services/messaging/campaigns/contact_lists/update.rb`
- Create: `app/services/messaging/campaigns/contact_lists/import.rb`
- Create: `app/services/messaging/campaigns/contact_lists/append.rb`
- Create: `app/services/messaging/campaigns/contact_lists/replace.rb`
- Create: `app/services/messaging/campaigns/contact_lists/add_entry.rb`
- Create: `app/services/messaging/campaigns/contact_lists/remove_entry.rb`
- Create: `app/services/messaging/campaigns/templates/render.rb`
- Create: `app/services/messaging/campaigns/templates/variables.rb`
- Create: `app/services/messaging/campaigns/templates/sms_segment_counter.rb`
- Create: `app/services/messaging/campaigns/attest.rb`
- Create: `app/services/messaging/campaigns/suppressions/record.rb`
- Create: `app/services/messaging/campaigns/suppressions/process_inbound.rb`
- Create: `app/services/messaging/campaigns/suppressions/unsubscribe.rb`
- Create: `app/services/messaging/campaigns/unsubscribe_token.rb`
- Create: `app/services/messaging/campaigns/abuse_guard.rb`
- Create: `app/services/messaging/campaigns/credit_holds/reserve.rb`
- Create: `app/services/messaging/campaigns/credit_holds/allocate.rb`
- Create: `app/services/messaging/campaigns/credit_holds/settle.rb`
- Create: `app/services/messaging/campaigns/credit_holds/finalize.rb`
- Create: `app/services/messaging/campaigns/deliver.rb`
- Create: `app/services/messaging/campaigns/links/create.rb`
- Create: `app/services/messaging/campaigns/analytics.rb`
- Create: `app/services/messaging/campaigns/channel_address.rb`
- Create: `app/services/messaging/campaigns/lifecycle_command_support.rb`
- Create: `app/services/messaging/campaigns/credit_holds/allocation_identity.rb`
- Create: `app/services/messaging/campaigns/credit_holds/settlement_support.rb`
- Create: `app/services/messaging/outbox_handlers/campaign_launched.rb`

### Jobs and provider seam

- Create: `app/jobs/messaging/import_campaign_contact_list_job.rb`
- Create: `app/jobs/messaging/prepare_campaign_audience_job.rb`
- Create: `app/jobs/messaging/fanout_campaign_job.rb`
- Create: `app/jobs/messaging/process_scheduled_campaigns_job.rb`
- Create: `app/jobs/messaging/reconcile_campaigns_job.rb`
- Create: `app/jobs/messaging/recover_campaign_delivery_job.rb`
- Create: `app/jobs/messaging/purge_campaign_payloads_job.rb`
- Create: `app/services/messaging/providers/inbound_adapter.rb` and
  `inbound_registry.rb` for verified provider webhook parsing.
- Modify: `config/initializers/messaging_outbox_handlers.rb` to register the
  exact `messaging.campaign.launched` handler.
- Modify: `config/initializers/messaging.rb` only if campaign provider adapters
  need explicit registration; keep the existing in-app registration intact.
- Modify: `config/recurring.yml` to schedule import recovery, campaign
  reconciliation, and campaign payload purge on separate maintenance minutes.
- Modify: `config/queue.yml` only if the existing wildcard worker needs an
  explicit `campaigns` queue; do not create a duplicate worker on preview.

### API, authorization, serialization, and documentation

- Create: `app/controllers/messaging/campaigns_controller.rb`
- Create: `app/controllers/messaging/campaign_contact_lists_controller.rb`
- Create: `app/controllers/messaging/campaign_contact_list_imports_controller.rb`
- Create: `app/controllers/messaging/campaign_templates_controller.rb`
- Create: `app/controllers/messaging/campaign_contact_list_entries_controller.rb`
- Create: `app/controllers/messaging/campaign_webhooks_controller.rb`
- Create: `app/controllers/messaging/campaign_unsubscribes_controller.rb`
- Create: `app/controllers/admin/messaging/campaigns_controller.rb`
- Create: `app/controllers/admin/messaging/campaign_templates_controller.rb`
- Create: `app/controllers/admin/messaging/campaign_volume_policies_controller.rb`
- Create: `app/policies/messaging/campaign_policy.rb`
- Create: `app/policies/messaging/campaign_contact_list_policy.rb`
- Create: `app/policies/messaging/campaign_contact_list_entry_policy.rb`
- Create: `app/policies/messaging/campaign_template_policy.rb`
- Create: `app/policies/messaging/campaign_volume_policy.rb`
- Create: `app/serializers/messaging/campaign_serializer.rb`
- Create: `app/serializers/messaging/campaign_contact_list_serializer.rb`
- Create: `app/serializers/messaging/campaign_contact_list_import_serializer.rb`
- Create: `app/serializers/messaging/campaign_template_serializer.rb`
- Create: `app/serializers/messaging/campaign_volume_policy_serializer.rb`
- Modify: `config/routes.rb` with the organizer, inbound webhook, and public
  unsubscribe routes.
- Create: `config/locales/messaging/campaigns.en.yml`
- Modify: `postman/Digis API_collection.json` with every route, request body,
  missing-key response, replay response, and representative success/error data.
- Modify: `db/seeds/preview.rb` with synthetic lists/templates/campaigns and
  valid credit fixtures; never seed a provider secret or real contact.
- Modify: `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md`
  after acceptance to mark the campaign phase implementation checkpoint.

### Tests

- Create: `test/models/messaging/campaign_schema_test.rb`
- Create: `test/models/messaging/campaign_test.rb`
- Create: `test/models/messaging/campaign_contact_list_test.rb`
- Create: `test/models/messaging/campaign_template_test.rb`
- Create: `test/models/messaging/campaign_suppression_test.rb`
- Create: `test/services/messaging/campaigns/templates/sms_segment_counter_test.rb`
- Create: `test/services/messaging/campaigns/templates/render_test.rb`
- Create: `test/services/messaging/campaigns/contact_lists/import_test.rb`
- Create: `test/services/messaging/campaigns/audience/resolve_test.rb`
- Create: `test/services/messaging/campaigns/audience/snapshot_test.rb`
- Create: `test/services/messaging/campaigns/credit_holds_test.rb`
- Create: `test/services/messaging/campaigns/lifecycle_test.rb`
- Create: `test/services/messaging/campaigns/cancel_test.rb`
- Create: `test/services/messaging/campaigns/suppressions_test.rb`
- Create: `test/services/messaging/campaigns/links_test.rb`
- Create: `test/jobs/messaging/import_campaign_contact_list_job_test.rb`
- Create: `test/jobs/messaging/prepare_campaign_audience_job_test.rb`
- Create: `test/jobs/messaging/fanout_campaign_job_test.rb`
- Create: `test/jobs/messaging/process_scheduled_campaigns_job_test.rb`
- Create: `test/jobs/messaging/reconcile_campaigns_job_test.rb`
- Create: `test/integration/messaging/campaigns_test.rb`
- Create: `test/integration/messaging/campaign_contact_lists_test.rb`
- Create: `test/integration/messaging/campaign_templates_test.rb`
- Create: `test/integration/messaging/campaign_unsubscribe_test.rb`
- Create: `test/integration/messaging/campaign_webhooks_test.rb`
- Create: `test/integration/messaging/campaign_contact_list_import_reports_test.rb`
- Create: `test/integration/admin/messaging/campaigns_test.rb`
- Create: `test/performance/messaging_campaign_fanout_test.rb`
- Create: `test/services/messaging/outbox_handlers/campaign_launched_test.rb`
- Create: `test/services/messaging/providers/inbound_registry_test.rb`
- Create: `test/support/messaging_campaign_test_helpers.rb`

## Task 1: Establish schema and credit-contract boundaries

**Files:**
- Create the 15 campaign migrations listed above.
- Modify `db/migrate/20260904090004_create_messaging_credit_reservations.rb`.
- Modify `app/models/messaging/credit_reservation.rb` and
  `app/models/messaging/credit_ledger_entry.rb`.
- Test: `test/models/messaging/campaign_schema_test.rb`.

- [x] **Step 1: Write schema-failure tests**

Add assertions for the exact database boundaries:

```ruby
test "credit reservations accept only campaign or campaign-recipient sources" do
  assert_includes Messaging::CreditReservation::SOURCE_TYPES, "Messaging::Campaign"
  assert_includes Messaging::CreditReservation::SOURCE_TYPES, "Messaging::CampaignRecipient"
end

test "campaign recipient deduplication is database-enforced" do
  first = build_campaign_recipient
  duplicate = first.dup
  assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
end

test "suppression supports global and organization scopes" do
  assert Messaging::CampaignSuppression.new(
    channel: "sms", channel_address_digest: "a" * 64, source: "provider",
    reason: "stop", suppressed_at: Time.current,
    idempotency_key_digest: "b" * 64
  ).valid?
  assert Messaging::CampaignSuppression.new(
    organization: organizations_organizations(:one), channel: "sms",
    channel_address_digest: "c" * 64, source: "organizer",
    reason: "unsubscribe", suppressed_at: Time.current,
    idempotency_key_digest: "d" * 64
  ).valid?
end

test "campaign scheduling and quote fields are explicit" do
  campaign = build_campaign(timezone: "Africa/Addis_Ababa")
  assert_equal "Africa/Addis_Ababa", campaign.timezone
  assert_equal 1, campaign.launch_version
  assert campaign.respond_to?(:quoted_rate_version_id)
  assert campaign.respond_to?(:quoted_quantity)
  assert campaign.respond_to?(:quoted_unit_price_minor)
  assert campaign.respond_to?(:quote_digest)
  assert campaign.respond_to?(:quoted_at)
  assert campaign.respond_to?(:quote_expires_at)
end
```

- [x] **Step 2: Run the schema tests and confirm the new symbols are absent**

Run:

```bash
bin/rails test test/models/messaging/campaign_schema_test.rb
```

Expected: FAIL because the campaign tables, models, and aggregate source type
do not exist yet.

- [x] **Step 3: Create one-table migrations with explicit constraints**

Use UUIDv7 primary keys and explicit FKs. The existing credit reservation
migration must change its source check to:

```ruby
add_check_constraint :messaging_credit_reservations,
  "source_type IS NULL OR source_type IN ('Messaging::Campaign','Messaging::CampaignRecipient')",
  name: "messaging_credit_reservations_source_type_check"
```

The campaign tables must include these database boundaries:

```sql
channel IN ('sms','email')
status IN ('draft','scheduled','sending','paused','canceled','completed','failed')
quantity > 0
timezone <> ''
launch_version > 0
(quote_digest IS NULL OR quote_digest ~ '^[0-9a-f]{64}$')
(quoted_at IS NULL AND quote_expires_at IS NULL) OR (quoted_at IS NOT NULL AND quote_expires_at > quoted_at)
(quoted_rate_version_id IS NULL AND quoted_quantity IS NULL AND quoted_unit_price_minor IS NULL AND quote_digest IS NULL AND quoted_at IS NULL AND quote_expires_at IS NULL) OR (quoted_rate_version_id IS NOT NULL AND quoted_quantity IS NOT NULL AND quoted_unit_price_minor IS NOT NULL AND quote_digest IS NOT NULL AND quoted_at IS NOT NULL AND quote_expires_at IS NOT NULL)
(completed_at IS NULL OR status = 'completed')
(canceled_at IS NULL OR status = 'canceled')
jsonb_typeof(metadata) = 'object'
```

`messaging_campaigns` also stores the immutable rendered-message snapshot in
encrypted `message_subject_ciphertext`/`message_body_ciphertext` columns so a
template edit cannot change a launched campaign and retention can erase the
campaign copy without deleting reusable templates. `messaging_campaign_contact_list_imports`
has an Active Storage CSV attachment; the migration only stores import state,
counts, errors, and timestamps because Active Storage owns blob metadata.

The campaign migration must declare these fields explicitly:

```ruby
t.integer :launch_version, null: false, default: 1
t.uuid :quoted_rate_version_id
t.bigint :quoted_quantity
t.bigint :quoted_unit_price_minor
t.string :quote_digest, limit: 64
t.timestamptz :quoted_at
t.timestamptz :quote_expires_at
```

Add unique indexes for `(organization_id, name)` on contact lists, `(list_id,
address_digest)` on entries, `(campaign_id, channel_address_digest)` on
recipients, `(campaign_id, recipient_id)` on deliveries, `(campaign_id,
delivery_id)` on allocations, `(organization_id, channel, address_digest)` on
organization suppressions, and `(channel, address_digest)` for global
suppression rows. Add partial claimable indexes for pending/processing
deliveries and pending imports.

Declare foreign keys in the same topological order as the migration list:
template versions reference templates; snapshots reference campaigns; recipients
reference snapshots; deliveries reference campaigns/recipients; allocations
reference deliveries and the existing credit reservation. Do not add an
`audience_snapshot_id` FK back from campaigns, which would create a migration
cycle; `Campaign` reaches its snapshot through the snapshot's `campaign_id`.
Use a unique `delivery_id` index for the one-to-one allocation association.

`messaging_campaigns.timezone` is required and stores a valid IANA zone per
campaign; no organization-table migration is added. `messaging_campaigns`
also stores `launch_version` (positive integer, default 1),
`quoted_rate_version_id`, `quoted_quantity`, `quoted_unit_price_minor`, `quote_digest`, `quoted_at`, and
`quote_expires_at`, `completed_at`, and `canceled_at`. `messaging_campaign_volume_policies`
stores its own required IANA `timezone`; quota windows are calculated in that
policy zone, not in UTC or an implicit server zone.

Use `organization_id IS NULL` as the global-suppression scope and
`nulls_not_distinct: true` where a composite uniqueness boundary includes a
nullable organization ID. Add explicit FKs for every non-polymorphic relation.

- [x] **Step 4: Implement model constants and database-facing allowlists**

Set `CreditReservation::SOURCE_TYPES` to
`%w[Messaging::Campaign Messaging::CampaignRecipient]` and
`CreditLedgerEntry::REFERENCE_TYPES` to include `Messaging::Campaign` and
`Messaging::CampaignDelivery`. Add `ransackable_attributes` and
`ransackable_associations` to every campaign model. Add `encrypts` declarations
for contact address ciphertext columns and keep digest columns searchable.

- [x] **Step 5: Run migrations and schema tests**

Run:

```bash
bin/rails db:migrate
bin/rails test test/models/messaging/campaign_schema_test.rb
```

Expected: the schema tests pass and `db/structure.sql` contains the source,
status, JSON, uniqueness, partial-index, and foreign-key constraints.

- [ ] **Step 6: User-owned checkpoint**

Review the migration diff and, when satisfied, stage/commit the schema group:

```bash
git add db/migrate/20260906*create_messaging_campaign* \
  db/migrate/20260904090004_create_messaging_credit_reservations.rb \
  app/models/messaging/credit_reservation.rb \
  app/models/messaging/credit_ledger_entry.rb \
  db/structure.sql test/models/messaging/campaign_schema_test.rb
git commit -m "feat(messaging): add campaign persistence boundaries"
```

## Task 2: Implement campaign, list, template, and suppression models

**Files:**
- Create all campaign model files in the file map.
- Test: `test/models/messaging/campaign_test.rb`,
  `campaign_contact_list_test.rb`, `campaign_template_test.rb`, and
  `campaign_suppression_test.rb`.

- [x] **Step 1: Write model behavior tests**

Cover these exact invariants:

```ruby
test "channel cannot change after campaign launch" do
  campaign = build_campaign(status: "draft")
  campaign.update!(status: "scheduled")
  campaign.channel = "email"
  refute campaign.valid?
  assert_includes campaign.errors[:channel], :immutable
end

test "a contact entry requires at least one encrypted address" do
  entry = Messaging::CampaignContactListEntry.new(campaign_contact_list: build_contact_list)
  refute entry.valid?
  assert_includes entry.errors[:base], I18n.t("messaging.campaigns.errors.contact_required")
end

test "template versions reject unknown variables" do
  version = build_template_version
  version.body = "Hello {{unknown_variable}}"
  refute version.valid?
  assert_includes version.errors[:body], :unknown_variable
end

test "suppression is idempotent by scoped digest" do
  subject = -> { Messaging::Campaigns::Suppressions::Record.call(
    channel: "sms", channel_address_digest: "c" * 64,
    reason: "stop", idempotency_key: "suppression-1"
  ) }
  assert_idempotent(subject, counter: -> { Messaging::CampaignSuppression.count })
end
```

- [x] **Step 2: Run the model tests to verify they fail for missing behavior**

Run:

```bash
bin/rails test test/models/messaging/campaign_test.rb \
  test/models/messaging/campaign_contact_list_test.rb \
  test/models/messaging/campaign_template_test.rb \
  test/models/messaging/campaign_suppression_test.rb
```

Expected: FAIL on missing constants, validations, and associations.

- [x] **Step 3: Implement small, explicit model contracts**

Use string status constants and validations, not enums. `Campaign` exposes
`SMS`/`EMAIL`, lifecycle predicates, immutable-after-launch validation, and
decrypted accessors backed by `message_subject_ciphertext` and
`message_body_ciphertext`; it validates positive `launch_version` and does not
permit launch-version changes after launch. `CampaignContactListEntry` exposes decrypted
`phone_number`/`email` accessors backed by encrypted columns and stores keyed
digests. `CampaignTemplateVersion` stores sanitized locale content and an
allowlisted variable list. Every model must declare Ransack allowlists and
avoid `AuditableModel` for high-volume derived recipient/delivery rows;
auditable commands write `Core::AuditLog` records separately.

`CampaignDelivery` declares `has_one :credit_allocation`; the database enforces
the same one-to-one contract with a unique `delivery_id` index. Tests use
`delivery.credit_allocation`, never a plural collection.

Create `test/support/messaging_campaign_test_helpers.rb` with builders that
use `organizations_organizations(:one)`, `core_users(:super_admin)`, and
existing event fixtures: `build_campaign`, `build_campaign_with_rendered_message`,
`build_contact_list`, `build_contact_entry_with_email`,
`build_template_version`, `build_campaign_recipient`, and
`build_campaign_delivery`. Builders must persist only the rows needed by the
test and must never bypass campaign commands in lifecycle/settlement tests.

- [x] **Step 4: Run model tests and RuboCop on touched models**

Run:

```bash
bin/rails test test/models/messaging/campaign_test.rb \
  test/models/messaging/campaign_contact_list_test.rb \
  test/models/messaging/campaign_template_test.rb \
  test/models/messaging/campaign_suppression_test.rb
bundle exec rubocop app/models/messaging
```

Expected: all focused model tests pass and RuboCop reports no offenses.

- [ ] **Step 5: User-owned checkpoint**

```bash
git add app/models/messaging/campaign*.rb \
  test/models/messaging/campaign*.rb test/support/messaging_campaign_test_helpers.rb
git commit -m "feat(messaging): add campaign domain models"
```

## Task 3: Add SMS segment accounting and localized template rendering

**Files:**
- Create: `app/services/messaging/campaigns/templates/variables.rb`,
  `sms_segment_counter.rb`, and `render.rb`.
- Test: `test/services/messaging/campaigns/templates/sms_segment_counter_test.rb`
  and `render_test.rb`.
- Modify: `config/locales/messaging/campaigns.en.yml` for typed errors.

- [x] **Step 1: Write encoding-boundary tests**

The test cases must assert these exact quantities:

```ruby
test "counts GSM-7 messages" do
  assert_equal 1, SmsSegmentCounter.call("a" * 160)
  assert_equal 2, SmsSegmentCounter.call("a" * 161)
  assert_equal 2, SmsSegmentCounter.call("a" * 306)
  assert_equal 3, SmsSegmentCounter.call("a" * 307)
end

test "counts UCS-2 messages including Amharic and emoji" do
  assert_equal 1, SmsSegmentCounter.call("ሰ" * 70)
  assert_equal 2, SmsSegmentCounter.call("ሰ" * 71)
  assert_equal 1, SmsSegmentCounter.call("😀" * 35)
  assert_equal 2, SmsSegmentCounter.call("😀" * 36)
  assert_equal 4, SmsSegmentCounter.call("😀" * 134)
  assert_equal 5, SmsSegmentCounter.call("😀" * 135)
end

test "GSM-7 extension characters consume two septets" do
  assert_equal 1, SmsSegmentCounter.call("{" * 80)
  assert_equal 2, SmsSegmentCounter.call("{" * 81)
end
```

- [x] **Step 2: Run the segment tests and confirm they fail**

```bash
bin/rails test test/services/messaging/campaigns/templates/sms_segment_counter_test.rb
```

Expected: FAIL because the counter is not defined.

- [x] **Step 3: Implement deterministic segment counting**

Use an explicit GSM-7 basic alphabet and extension set. Count extension
characters as two septets. Count UCS-2 by UTF-16 code units so non-BMP emoji
consume two units. Use 160/153 for GSM-7 and 70/67 for UCS-2:

```ruby
if gsm7?(body)
  septets = body.each_char.sum { |char| GSM7_EXTENSION.include?(char) ? 2 : 1 }
  septets <= 160 ? 1 : (septets.to_f / 153).ceil
else
  units = body.encode("UTF-16BE").bytesize / 2
  units <= 70 ? 1 : (units.to_f / 67).ceil
end
```

Reject blank bodies and unsupported control characters before counting. Expose
`units_for(channel:, body:)`, returning one for email and the segment count for
SMS. The rate resolver receives this unit quantity, so volume tiers price
credits rather than audience rows.

- [x] **Step 4: Implement variable validation and neutral fallback rendering**

`Templates::Variables` must allow only `event_name`, `event_date`, `venue_name`,
`ticket_link`, `first_name`, and `organization_name`. `Templates::Render` must
replace an absent `first_name` with `there` and other absent contextual values
with empty text, escape email HTML, preserve plain-text SMS,
and return the fully resolved body for preview and delivery.

- [x] **Step 5: Run rendering and segment tests**

```bash
bin/rails test test/services/messaging/campaigns/templates
bundle exec rubocop app/services/messaging/campaigns/templates
```

Expected: all encoding, fallback, locale, and variable-safety tests pass.

- [ ] **Step 6: User-owned checkpoint**

```bash
git add app/services/messaging/campaigns/templates \
  test/services/messaging/campaigns/templates \
  config/locales/messaging/campaigns.en.yml
git commit -m "feat(messaging): price SMS campaigns by message segments"
```

## Task 4: Build reusable contact-list ingestion

**Files:**
- Create contact-list command files and
  `app/jobs/messaging/import_campaign_contact_list_job.rb`.
- Test: `test/services/messaging/campaigns/contact_lists/import_test.rb` and
  `test/jobs/messaging/import_campaign_contact_list_job_test.rb`, plus
  `test/integration/messaging/campaign_contact_list_import_reports_test.rb`.

- [x] **Step 1: Write import and list-update tests**

Cover:

```ruby
test "rejects an import over the file-size limit" do
  result = ContactLists::Import.call(list:, blob: oversized_blob, actor:, idempotency_key: "import-1")
  assert_equal "contact_list_file_too_large", result.error.code
end

test "rejects an import over 10000 rows" do
  result = ContactLists::Import.call(list:, blob: csv_blob(rows: 10_001), actor:, idempotency_key: "import-2")
  assert_equal "contact_list_row_limit_exceeded", result.error.code
end

test "append and replace are distinct idempotent operations" do
  append = -> { ContactLists::Append.call(list:, rows: [ valid_row ], actor:, idempotency_key: "append-1") }
  assert_idempotent(append, counter: -> { list.entries.count })
  replace = ContactLists::Replace.call(list:, rows: [ replacement_row ], actor:, idempotency_key: "replace-1")
  assert replace.success?
  assert_equal [ replacement_row.fetch(:email) ], list.reload.entries.map(&:email)
end
```

- [x] **Step 2: Run contact-list tests to confirm missing pipeline behavior**

```bash
bin/rails test test/services/messaging/campaigns/contact_lists/import_test.rb \
  test/jobs/messaging/import_campaign_contact_list_job_test.rb \
  test/integration/messaging/campaign_contact_list_import_reports_test.rb
```

Expected: FAIL on missing commands/job and typed locale errors.

- [x] **Step 3: Implement asynchronous CSV import**

`ContactLists::Import` creates an import row, validates the attached Active
Storage blob is CSV and at most 5 MB, and enqueues `ImportCampaignContactListJob`
with only the import ID. The job streams rows with `CSV.foreach`, stops at
10,000 rows, normalizes phone/email, writes keyed digests and encrypted values,
and records counts for accepted/duplicate/invalid/suppressed/missing-channel
rows. Accepted entries are validated/encrypted in bounded 500-row batches and
persisted with `insert_all`; it must not load the entire file into memory or
hold one SQL insert per row. It writes an authorized
`rejected_report` Active Storage attachment containing only rejected rows;
every report cell beginning with `=`, `+`, `-`, or `@` is prefixed with a
single quote before CSV serialization.

Phone normalization must call the existing
`Core::PhoneIdentity::ResolveOrCreate.normalize` implementation so imported
contacts use the same canonical Ethiopian `+251` identity rules as users and
ticketing. Email normalization uses Unicode normalization, trim, and lowercase
before digesting.

- [x] **Step 4: Implement manual entries and append/replace**

Manual entries call the same row validator as CSV. Append inserts only new
address digests. Replace requires an explicit confirmation flag, records the
prior list version in an audit payload, and atomically swaps the active list
version. A list update never mutates an existing campaign snapshot.

- [x] **Step 5: Add list limits and import replay tests**

Assert at most 50 lists per organization, exact `Idempotency-Key` replay with
no duplicate import rows, and a changed request body returning
`idempotency_conflict`. Assert that job arguments are `[import.id]` and contain
no contact data. Assert the report endpoint returns a short-lived authorized
download URL and cannot be read by another organization.

- [x] **Step 6: Run focused tests and performance checks**

```bash
bin/rails test test/services/messaging/campaigns/contact_lists/import_test.rb \
  test/jobs/messaging/import_campaign_contact_list_job_test.rb \
  test/integration/messaging/campaign_contact_list_import_reports_test.rb
N_PLUS_ONE=1 bin/rails test test/jobs/messaging/import_campaign_contact_list_job_test.rb
```

Expected: all imports pass without strict-loading/N+1 violations.

- [ ] **Step 7: User-owned checkpoint**

```bash
git add app/services/messaging/campaigns/contact_lists \
  app/jobs/messaging/import_campaign_contact_list_job.rb \
  test/services/messaging/campaigns/contact_lists/import_test.rb \
  test/jobs/messaging/import_campaign_contact_list_job_test.rb \
  test/integration/messaging/campaign_contact_list_import_reports_test.rb
git commit -m "feat(messaging): add reusable campaign contact lists"
```

## Task 5: Resolve first-party audiences and create launch snapshots

**Files:**
- Create: `app/services/messaging/campaigns/audience/resolve.rb` and
  `snapshot.rb`.
- Create: `app/jobs/messaging/prepare_campaign_audience_job.rb`.
- Test: `test/services/messaging/campaigns/audience/resolve_test.rb` and
  `snapshot_test.rb`, plus
  `test/jobs/messaging/prepare_campaign_audience_job_test.rb`.

- [x] **Step 1: Write audience-resolution tests**

Assert these sources and semantics:

```ruby
test "unions and deduplicates event relationships and saved lists" do
  result = Audience::Resolve.call(
    organization:, channel: "sms",
    sources: [ { type: "event", event_id: event.id, basis: "checked_in" },
               { type: "contact_list", id: list.id } ]
  )
  assert_equal expected_digests.sort, result.value.map(&:channel_address_digest).sort
end

test "issued and checked-in historical bases are distinct" do
  issued = Audience::Resolve.call(organization:, channel: "email",
    sources: [ { type: "event", event_id: event.id, basis: "issued" } ])
  checked_in = Audience::Resolve.call(organization:, channel: "email",
    sources: [ { type: "event", event_id: event.id, basis: "checked_in" } ])
  refute_equal issued.value.map(&:id).sort, checked_in.value.map(&:id).sort
end

test "late suppression changes eligibility before snapshot launch" do
  Messaging::Campaigns::Suppressions::Record.call(channel: "sms", channel_address_digest: digest,
    reason: "stop", idempotency_key: "stop-1")
  result = Audience::Snapshot.call(campaign:, actor:, idempotency_key: "snapshot-1")
  assert_equal "suppressed", result.value.recipients.find_by(channel_address_digest: digest).eligibility_status
end
```

- [x] **Step 2: Run audience tests and confirm missing behavior**

```bash
bin/rails test test/services/messaging/campaigns/audience
```

Expected: FAIL until the source queries and snapshot command exist.

- [x] **Step 3: Implement bounded source queries**

Use `Ticketing::Registration`, `Ticketing::Ticket`, check-in/admission rows,
`Core::Follow` rows for organization subscribers, and contact-list entries.
Each source returns only IDs/digests needed for the selected channel. Union in
Ruby by normalized channel digest, preserve source labels, and sort by UUID
string for stable cursoring. Load all required associations up front; no
per-recipient queries.

`Audience::Snapshot` writes recipients with 500-row `insert_all` batches and
updates snapshot progress counters after each batch. `PrepareCampaignAudienceJob`
receives only the snapshot ID, resumes from the stored cursor, and transitions
the snapshot to `ready` or `failed`. Suppression lookups are performed per
500-row batch, and first-party materialization fails explicitly above the
10,000-candidate ceiling rather than exhausting worker memory.

- [x] **Step 4: Implement immutable snapshot creation**

`Audience::Snapshot` creates one snapshot and recipient rows under a unique
`(campaign_id, channel_address_digest)` boundary. Store selected source type,
event ID, historical basis, eligibility status/reason, and channel quantity
(SMS segment count or one email unit). Snapshot creation is idempotent by the
campaign/key digest and binds the organizer attestation version. `Estimate`
returns `202` with snapshot progress while preparation is pending; it returns a
quote only after the snapshot is ready.

- [x] **Step 5: Run N+1 and pagination tests**

```bash
N_PLUS_ONE=1 bin/rails test test/services/messaging/campaigns/audience
bin/rails test test/jobs/messaging/prepare_campaign_audience_job_test.rb
```

Expected: union, source-basis, suppression, dedupe, and strict-loading tests
pass.

- [ ] **Step 6: User-owned checkpoint**

```bash
git add app/services/messaging/campaigns/audience \
  app/jobs/messaging/prepare_campaign_audience_job.rb \
  test/services/messaging/campaigns/audience \
  test/jobs/messaging/prepare_campaign_audience_job_test.rb
git commit -m "feat(messaging): snapshot campaign audiences safely"
```

## Task 6: Implement attestation and suppression ingress

**Files:**
- Create attestation/suppression services, models already created in Task 1,
  controllers, and `test/integration/messaging/campaign_unsubscribe_test.rb` /
  `campaign_webhooks_test.rb`.
- Create: `app/services/messaging/providers/inbound_adapter.rb` and
  `inbound_registry.rb`, with `test/services/messaging/providers/inbound_registry_test.rb`.
- Create: `app/services/messaging/campaigns/unsubscribe_token.rb` and
  `abuse_guard.rb`.
- Modify: `config/routes.rb` and `config/locales/messaging/campaigns.en.yml`.

- [x] **Step 1: Write suppression tests**

Cover global and organization scope, channel scope, idempotent replay, signed
provider inbound events, SMS `STOP`, provider-defined equivalents, email
tokenized links, and invalid signatures:

```ruby
test "invalid provider signatures do not create suppression" do
  post "/messaging/webhooks/sms/inbound", params: inbound_payload.to_json,
    headers: { "X-Provider-Signature" => "bad", "Content-Type" => "application/json" }
  assert_response :unauthorized
  assert_not Messaging::CampaignSuppression.exists?(channel_address_digest: digest)
end

test "SMS STOP creates one global suppression and replays safely" do
  signed = sign_provider_payload(inbound_payload.merge(message: "STOP"))
  post "/messaging/webhooks/sms/inbound", params: signed.body,
    headers: signed.headers.merge("Content-Type" => "application/json")
  assert_response :success
  post "/messaging/webhooks/sms/inbound", params: signed.body,
    headers: signed.headers.merge("Content-Type" => "application/json")
  assert_response :success
  assert_equal 1, Messaging::CampaignSuppression.where(channel_address_digest: digest).count
end
```

- [x] **Step 2: Implement signed inbound processing and tokenized unsubscribe**

`Campaigns::Suppressions::ProcessInbound` verifies the provider adapter’s
signature over the raw body, deduplicates by provider event ID, normalizes the
address through `Core::PhoneIdentity::ResolveOrCreate.normalize` for SMS,
recognizes the adapter’s `stop_words` (with the standard default set), and calls the same suppression command
used by organizer/admin operations. `Providers::InboundAdapter` exposes
`verify_inbound(raw_body:, headers:)` and
`parse_inbound(raw_body:, headers:)`; `InboundRegistry` resolves it by provider
name and exposes `stop_words`. The public unsubscribe controller verifies a 30-day token from
`Rails.application.message_verifier("messaging-campaign-unsubscribe-v1")`
with purpose `campaign_unsubscribe`, containing only suppression
scope/channel/digest identity. Email delivery adds `List-Unsubscribe` and
`List-Unsubscribe-Post` URLs; SMS relies on inbound replies by default so an
opt-out URL does not consume another segment.

`Campaigns::AbuseGuard` uses `Rails.cache` and `request.remote_ip` to enforce
120 inbound webhook requests per provider/IP/minute and 30 public unsubscribe
requests per IP/minute, returning a typed 429 without changing suppression.
In production behind reverse proxies, `request.remote_ip` relies on
`config.action_dispatch.trusted_proxies` so proxy egress IPs are not throttled
as a single client.

- [x] **Step 3: Implement attestation command**

`Campaigns::Attest` requires an authorized organization member, channel, target
version, and explicit confirmation. It records actor, organization, list or
snapshot target, selected historical basis, timestamp, and attestation version.
It stores no raw contact export.

- [x] **Step 4: Run focused suppression/attestation tests**

```bash
bin/rails test test/services/messaging/campaigns/suppressions/suppressions_test.rb \
  test/integration/messaging/campaign_unsubscribe_test.rb \
  test/integration/messaging/campaign_webhooks_test.rb \
  test/services/messaging/providers/inbound_registry_test.rb
```

Expected: invalid signatures are 401, valid STOP/unsubscribe operations are
idempotent, and suppression wins over an organizer attestation.

- [ ] **Step 5: User-owned checkpoint**

```bash
git add app/services/messaging/campaigns/attest.rb \
  app/services/messaging/campaigns/suppressions \
  app/services/messaging/campaigns/unsubscribe_token.rb \
  app/services/messaging/campaigns/abuse_guard.rb \
  app/services/messaging/providers/inbound_adapter.rb \
  app/services/messaging/providers/inbound_registry.rb \
  app/controllers/messaging/campaign_webhooks_controller.rb \
  app/controllers/messaging/campaign_unsubscribes_controller.rb \
  test/services/messaging/campaigns/suppressions_test.rb \
  test/integration/messaging/campaign_unsubscribe_test.rb \
  test/integration/messaging/campaign_webhooks_test.rb \
  test/services/messaging/providers/inbound_registry_test.rb \
  config/routes.rb config/locales/messaging/campaigns.en.yml
git commit -m "feat(messaging): enforce campaign attestation and suppression"
```

## Task 7: Add campaign lifecycle, quotas, and aggregate credit holds

**Files:**
- Create lifecycle and credit-hold service files from the file map.
- Modify: `app/services/messaging/credit_accounts/command_support.rb` and
  `app/models/messaging/credit_reservation.rb`.
- Test: `test/services/messaging/campaigns/credit_holds_test.rb`,
  `lifecycle_test.rb`, `lifecycle_concurrency_test.rb`, and `cancel_test.rb`.

- [x] **Step 1: Write lifecycle/hold tests**

Cover quote quantity, rate snapshot, quota rejection, insufficient credits,
aggregate hold replay, allocation bounds, settlement, abort release, and
concurrent launch:

```ruby
test "SMS quote uses segment quantity rather than recipient count" do
  result = Campaigns::Estimate.call(campaign:, body: "ሰ" * 71, locale: "am")
  assert_equal 2 * eligible_recipient_count, result.value.fetch(:quantity)
end

test "launch creates one aggregate hold" do
  operation = -> { Campaigns::Launch.call(campaign:, actor:, idempotency_key: "launch-1") }
  assert_idempotent(operation, counter: -> {
    Messaging::CreditReservation.where(source_type: "Messaging::Campaign").count
  })
  assert_equal 1, Messaging::CreditReservation.where(source_id: campaign.id).count
end

test "abort releases only the unallocated hold remainder" do
  launch_campaign!
  allocate_and_settle_delivery!(quantity: 2, outcome: :success)
  result = Campaigns::Abort.call(campaign:, actor:, reason: "wrong_date",
    idempotency_key: "abort-1")
  assert result.success?
  assert_equal "canceled", campaign.reload.status
  hold = Messaging::CreditReservation.find_by!(
    source_type: "Messaging::Campaign", source_id: campaign.id
  )
  assert_equal "campaign_aborted", hold.reload.resolution_code
end

test "launch rejects a stale or mismatched quote" do
  estimate_campaign!
  result = Campaigns::Launch.call(
    campaign:, actor:, idempotency_key: "launch-stale-1",
    quote_digest: "0" * 64, quoted_rate_version_id: campaign.quoted_rate_version_id,
    quoted_quantity: campaign.quoted_quantity
  )
  assert_equal "campaign_quote_stale", result.error.code
  assert_not Messaging::CreditReservation.exists?(source_id: campaign.id)
end

test "cancel releases the full hold before dispatch" do
  launch_campaign!(send_at: 1.hour.from_now)
  result = Campaigns::Cancel.call(campaign:, actor:, reason: "withdrawn",
    idempotency_key: "cancel-1")
  assert result.success?
  assert_equal "canceled", campaign.reload.status
  assert_equal "campaign_canceled", Messaging::CreditReservation.find_by!(
    source_type: "Messaging::Campaign", source_id: campaign.id
  ).resolution_code
end
```

- [x] **Step 2: Implement aggregate hold reservation**

`CreditHolds::Reserve` locks one `CreditAccount`, verifies the selected rate,
quota, organization, channel, and available derived balance, then creates one
`CreditReservation` with `source_type: "Messaging::Campaign"` and
`source_id: campaign.id`. It appends exactly one `reserve` ledger entry. It
must not call the per-recipient `Reserve` service in a loop.

- [x] **Step 3: Implement allocation and settlement semantics**

`CreditHolds::Allocate` locks the aggregate reservation and creates one
allocation row per delivery, rejecting sums greater than the hold quantity.
Singular and batch allocation use the same canonical allocation digest.
`CreditHolds::Settle` appends one immutable ledger entry per outcome:

| Outcome | Ledger entry | Available delta |
|---|---|---:|
| delivered | `consume` | 0 |
| suppressed before provider call | `release` | allocation quantity |
| permanent provider failure | `refund` | allocation quantity |
| retryable failure | no terminal entry | 0 |

`CreditHolds::Finalize` marks the aggregate reservation terminal only after all
allocations and the unallocated remainder have settled. It does not append a
second full-quantity ledger entry. A replay with the same operation key returns
the stored allocation/settlement; a different request identity returns
`credit_idempotency_conflict`. Singular and batch settlement share one terminal
state/replay policy and canonical ledger identity.

- [x] **Step 4: Implement estimate, create/update, launch, pause, abort**

`Campaigns::Create` fixes the channel and organization. `Update` is allowed only
in `draft`. `Estimate` resolves the audience snapshot, segment quantity, rate
version, quota, and available balance without changing credit balances or
dispatching. `Estimate` persists the
quote fields (`quoted_rate_version_id`, `quoted_quantity`, `quoted_unit_price_minor`, `quote_digest`,
`quoted_at`, and `quote_expires_at = quoted_at + 15.minutes`) and returns `202`
until the audience snapshot is ready. `Launch` requires matching `quote_digest`,
`quoted_rate_version_id`, `quoted_quantity`, and `quoted_unit_price_minor`, rejects an expired/mismatched
quote with `campaign_quote_stale`, rechecks attestation/quota/credits, creates
the aggregate hold, transitions to `scheduled` or `sending`, and publishes
exactly one outbox event:

Compute the digest identically in Estimate, Launch, and seed helpers:

```ruby
quoted_at = Time.current
quote_digest = Core::KeyedDigest.digest(
  namespace: "messaging-campaign-quote",
  value: "#{campaign.id}:#{quoted_rate_version_id}:#{quoted_quantity}:#{quoted_at.to_i}"
)
```

Persist all quote fields together. The database accepts either an entirely
empty quote or a complete quote, using these guarded checks:

```sql
(quote_digest IS NULL OR quote_digest ~ '^[0-9a-f]{64}$')
(quoted_at IS NULL AND quote_expires_at IS NULL)
  OR (quoted_at IS NOT NULL AND quote_expires_at > quoted_at)
(quoted_rate_version_id IS NULL AND quoted_quantity IS NULL AND quote_digest IS NULL
  AND quoted_at IS NULL AND quote_expires_at IS NULL)
  OR (quoted_rate_version_id IS NOT NULL AND quoted_quantity IS NOT NULL
  AND quote_digest IS NOT NULL AND quoted_at IS NOT NULL AND quote_expires_at IS NOT NULL)
```

```ruby
Core::Outbox::Publish.call(
  topic: "messaging", event_type: "messaging.campaign.launched",
  aggregate: campaign,
  payload: {
    "campaign_id" => campaign.id,
    "credit_hold_id" => hold.id,
    "dispatch_at" => campaign.send_at&.iso8601,
    "launch_version" => campaign.launch_version
  },
  idempotency_key: "messaging-campaign-launched-#{campaign.id}-v#{campaign.launch_version}"
)
```

`Pause` is allowed in `scheduled`/`sending`; `Cancel` is allowed in `draft`/
`scheduled` before dispatch and releases the full hold; `Abort` is allowed in
`paused`/`sending`, stops future claims, releases the unallocated hold with
`campaign_aborted`, and transitions to terminal `canceled` under the campaign
lock. Allocated in-flight deliveries remain unsettled until their provider
outcome is known; reconciliation finalizes the hold once those allocations are
terminal. Pause, Cancel, Abort, and Resume record one request-bound audit row
with the actor, transition, reason (when applicable), and idempotency key; an
exact replay returns the existing transition without a second audit or enqueue.

- [x] **Step 5: Add concurrency and idempotency tests**

Use two threads against the same campaign/key and assert one launch audit, one
aggregate reservation, one rate snapshot, and no negative available balance.
Use shared `assert_idempotent` and `assert_audit_idempotent` helpers.

- [x] **Step 6: Run lifecycle/hold tests**

```bash
bin/rails test test/services/messaging/campaigns/credit_holds_test.rb \
  test/services/messaging/campaigns/lifecycle_test.rb \
  test/services/messaging/campaigns/cancel_test.rb
```

Expected: all hold, allocation, settlement, quota, abort, replay, and race
tests pass.

- [ ] **Step 7: User-owned checkpoint**

```bash
git add app/services/messaging/campaigns \
  app/services/messaging/credit_accounts/command_support.rb \
  app/models/messaging/credit_reservation.rb \
  test/services/messaging/campaigns/credit_holds_test.rb \
  test/services/messaging/campaigns/lifecycle_test.rb \
  test/services/messaging/campaigns/cancel_test.rb
git commit -m "feat(messaging): add campaign lifecycle and aggregate holds"
```

## Task 8: Deliver campaigns through bounded provider jobs

**Files:**
- Modify: `app/services/messaging/providers/adapter.rb`.
- Create: `app/jobs/messaging/fanout_campaign_job.rb`.
- Create: `app/services/messaging/campaigns/deliver.rb` for one-delivery
  claiming, provider invocation, and credit settlement.
- Create: `app/jobs/messaging/process_scheduled_campaigns_job.rb`.
- Create: `app/services/messaging/outbox_handlers/campaign_launched.rb` and
  register it in `config/initializers/messaging_outbox_handlers.rb`.
- Test: `test/jobs/messaging/fanout_campaign_job_test.rb`,
  `test/jobs/messaging/process_scheduled_campaigns_job_test.rb`, and
  `test/performance/messaging_campaign_fanout_test.rb`.

- [x] **Step 1: Write provider and fan-out tests**

Assert the adapter receives a campaign delivery without transactional
notification arguments, jobs carry IDs/cursors only, and 100-recipient pages
do not hold a transaction over provider I/O:

```ruby
test "fanout processes one bounded page and re-enqueues the cursor" do
  campaign = launch_campaign_with_recipients(101)
  Messaging::FanoutCampaignJob.perform_now(campaign.id)
  assert_equal 100, campaign.reload.deliveries.where(status: "delivered").count
  follow_up = enqueued_jobs.find { |job| job[:job] == Messaging::FanoutCampaignJob }
  assert follow_up
  assert_equal campaign.id, follow_up[:args].first
  assert follow_up[:args].last.fetch("after_recipient_id").present?
end

test "suppressed delivery releases its allocated quantity" do
  delivery = build_campaign_delivery(status: "pending", suppressed: true)
  result = Messaging::Campaigns::Deliver.call(delivery_id: delivery.id)
  assert result.success?
  assert_equal "released", delivery.reload.credit_allocation.status
end

test "launch outbox event hands off exactly once" do
  campaign, hold = launch_campaign!
  event = Core::OutboxEvent.find_by!(event_type: "messaging.campaign.launched")
  assert_equal campaign.id, event.payload.fetch("campaign_id")
  assert_equal hold.id, event.payload.fetch("credit_hold_id")
  Core::Outbox::Dispatch.call(event_id: event.id)
  assert_no_difference -> { Core::OutboxEvent.where(event_type: "messaging.campaign.launched").count } do
    Campaigns::Launch.call(campaign:, actor:, idempotency_key: "launch-1")
  end
end
```

- [x] **Step 2: Extend the adapter contract**

Add `deliver_campaign(campaign:, delivery:, content:, idempotency_key:)` to the
provider adapter. Keep `deliver(notification:, delivery:, content:,
idempotency_key:)` unchanged for transactional notifications. The campaign
service passes resolved content and expected credit quantity from persisted
rows; adapter implementations return only `Providers::DeliveryResult`.

- [x] **Step 3: Implement bounded fan-out and settlement**

`FanoutCampaignJob` loads the campaign by ID, claims 100 pending recipients
with `FOR UPDATE SKIP LOCKED`, allocates each delivery against the aggregate
hold, commits, and only then performs provider calls. Each provider call is
outside the database lock. It settles through `CreditHolds::Settle`, retries
retryable outcomes with bounded exponential backoff, refunds a delivery after
five attempts (including provider exceptions), logs only IDs/error codes, and
enqueues the next cursor. It stops immediately when campaign status is `paused`
or `canceled`.

`Campaigns::Deliver` resolves allowlisted template variables for the recipient
and campaign context before invoking the provider. Missing values use the
neutral fallback; unknown variables fail validation, and no provider receives
literal `{{...}}` tokens.

`Messaging::OutboxHandlers::CampaignLaunched` is registered at priority 200 for
`messaging.campaign.launched`. It loads only the campaign and hold IDs from the
payload, enqueues `FanoutCampaignJob(campaign.id)` when `dispatch_at` is due,
and otherwise leaves the campaign for `ProcessScheduledCampaignsJob`. Replaying
the same outbox row performs no second launch or hold creation; duplicate job
delivery is harmless because recipient claims and allocations are unique. After
the final page, the job locks the campaign, confirms no eligible recipients or
non-terminal deliveries remain, finalizes any unallocated hold remainder, and
records `completed_at` before marking the campaign `completed`.

Register it in `config/initializers/messaging_outbox_handlers.rb` with the same
error propagation convention as the existing handlers:

```ruby
Rails.application.config.after_initialize do
  Rails.application.config.x.outbox_handlers.register(
    "messaging.campaign.launched", priority: 200
  ) do |outbox_event|
    result = Messaging::OutboxHandlers::CampaignLaunched.call(event: outbox_event)
    raise result.error if result.failure?

    result
  end
end
```

`ProcessScheduledCampaignsJob` runs every minute, claims at most 100 campaigns
where `status = 'scheduled'` and `send_at <= Time.current` with `SKIP LOCKED`,
transitions each to `sending`, and enqueues `FanoutCampaignJob` with the
campaign ID. A canceled or paused campaign is never re-enqueued. The job does
not call a provider or carry message content.

- [x] **Step 4: Add N+1/strict-loading coverage**

Run the performance test with 100 and 200 recipients and assert the query count
does not grow with recipient count. Assert no contact value, message body, or
provider credential appears in the serialized job arguments.

- [x] **Step 5: Run delivery tests**

```bash
N_PLUS_ONE=1 bin/rails test test/jobs/messaging/fanout_campaign_job_test.rb \
  test/jobs/messaging/process_scheduled_campaigns_job_test.rb \
  test/performance/messaging_campaign_fanout_test.rb
```

Expected: bounded pages, pause/abort, retry, provider outcomes, and credit
settlement pass without N+1 violations.

- [ ] **Step 6: User-owned checkpoint**

```bash
git add app/services/messaging/providers/adapter.rb \
  app/jobs/messaging/fanout_campaign_job.rb \
  app/jobs/messaging/process_scheduled_campaigns_job.rb \
  app/services/messaging/campaigns/deliver.rb \
  app/services/messaging/outbox_handlers/campaign_launched.rb \
  config/initializers/messaging_outbox_handlers.rb \
  test/jobs/messaging/fanout_campaign_job_test.rb \
  test/jobs/messaging/process_scheduled_campaigns_job_test.rb \
  test/services/messaging/outbox_handlers/campaign_launched_test.rb \
  test/performance/messaging_campaign_fanout_test.rb
git commit -m "feat(messaging): deliver campaigns in bounded pages"
```

## Task 9: Add tracked links and aggregate campaign analytics

**Files:**
- Create: `app/services/messaging/campaigns/links/create.rb` and
  `app/services/messaging/campaigns/analytics.rb`.
- Create: `app/models/messaging/campaign_link.rb` and
  `app/serializers/messaging/campaign_link_serializer.rb`.
- Test: `test/services/messaging/campaigns/links_test.rb` and analytics
  assertions in `test/integration/messaging/campaigns_test.rb`.

- [x] **Step 1: Write link contract tests**

```ruby
test "campaign link uses existing custom URL and UTM fields" do
  result = Messaging::Campaigns::Links::Create.call(
    campaign:, actor:, destination_url: "https://digis.et/events/#{event.slug}"
  )
  link = result.value
  assert_equal "https://digis.et/events/#{event.slug}", link.custom_url
  assert_equal campaign.id, link.utm_campaign
  assert_equal campaign.channel, link.utm_source
  assert_nil link.target_type
end
```

- [x] **Step 2: Implement link creation through `Links::Create`**

Use an authorized `custom_url`, `utm_campaign: campaign.id`,
`utm_source: campaign.channel`, and `utm_medium: "messaging_campaign"`. Do
not add `campaign` to `Links::ShortLink::TARGET_TYPES`; the campaign link row
owns the campaign association and the existing redirect/click model owns
redirect analytics.

- [x] **Step 3: Implement aggregate analytics**

Query `Links::ShortLinkClick` by campaign links and group by campaign/link/time
bucket. Return sent, delivered, failed, suppressed, consumed, refunded, and
click totals. Never expose recipient-level link identity or provider IDs.

- [x] **Step 4: Run link/analytics tests**

```bash
bin/rails test test/services/messaging/campaigns/links_test.rb \
  test/integration/messaging/campaigns_test.rb
```

Expected: link ownership, UTM values, aggregate click counts, and serializer
privacy pass.

- [ ] **Step 5: User-owned checkpoint**

```bash
git add app/services/messaging/campaigns/links \
  app/services/messaging/campaigns/analytics.rb \
  app/models/messaging/campaign_link.rb \
  app/serializers/messaging/campaign_link_serializer.rb \
  test/services/messaging/campaigns/links_test.rb
git commit -m "feat(messaging): add campaign link analytics"
```

## Task 10: Build organizer/admin API contracts

**Files:**
- Create all campaign controllers, policies, and serializers in the file map.
- Modify: `config/routes.rb` and locale files.
- Test: organizer/admin integration tests in the file map.

- [x] **Step 1: Write integration tests before controllers**

Cover these routes and responses:

```ruby
test "missing launch key returns 400" do
  post launch_path, headers: admin_headers, as: :json
  assert_response :bad_request
  assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
end

test "missing estimate key returns 400" do
  post estimate_path, headers: admin_headers, as: :json
  assert_response :bad_request
  assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
end

test "organizer launch response contains safe campaign fields" do
  post launch_path, headers: admin_headers.merge("Idempotency-Key" => "launch-api-1"), as: :json
  assert_response :success
  data = JSON.parse(response.body).fetch("data")
  assert_equal %w[channel id name status].sort, data.keys.grep(/id|name|channel|status/).sort
  refute data.key?("encrypted_contact")
  refute data.key?("provider_message_id")
  refute data.key?("credit_ledger_entries")
end

test "cross-organization campaign access is not found" do
  get "/organizations/#{other_org.id}/campaigns/#{campaign.id}", headers: admin_headers, as: :json
  assert_response :not_found
end
```

- [x] **Step 2: Implement organizer routes and controllers**

Add these exact routes:

```ruby
scope "organizations/:organization_id", module: :messaging do
  resources :campaigns, only: %i[index show create update] do
    post :estimate, on: :member
    post :attest, on: :member
    post :launch, on: :member
    post :pause, on: :member
    post :resume, on: :member
    post :cancel, on: :member
    post :abort, on: :member
    get :analytics, on: :member
  end
  resources :campaign_contact_lists, only: %i[index show create update destroy] do
    post :import, on: :member
    post :append, on: :member
    post :replace, on: :member
    resources :entries, controller: "campaign_contact_list_entries", only: %i[create destroy]
  end
  resources :campaign_templates, only: %i[index show create update]
  get "campaign_contact_lists/:id/imports/:import_id",
    to: "campaign_contact_list_imports#show"
  get "campaign_contact_lists/:id/imports/:import_id/report",
    to: "campaign_contact_list_imports#report"
end
post "messaging/webhooks/:provider/inbound", to: "messaging/campaign_webhooks#create"
get "messaging/unsubscribe/:token", to: "messaging/campaign_unsubscribes#show"
post "messaging/unsubscribe/:token", to: "messaging/campaign_unsubscribes#create"
namespace :admin do
  namespace :messaging do
    resources :campaigns, only: %i[index show]
    resources :campaign_templates, only: %i[index show create update]
    resources :campaign_volume_policies, only: %i[index show update]
  end
end
```

Every mutating action uses `ensure_idempotency_key_present`, `model_params`,
`eager_load_config`, `allowed_order_columns`, and a policy-gated
`serializer_profile`. `show`/`index` responses include only campaign display
state, counts, quote/rate snapshot, and aggregate analytics. The member
`analytics` action stays on `Messaging::CampaignsController#analytics` and
invokes `Messaging::Campaigns::Analytics` and renders its aggregate hash
directly; no dead serializer or separate analytics controller is created.
Campaign variable values are organizer-safe and returned as `variables`;
contact ciphertext,
digests, attestation evidence details, outbox IDs, and provider IDs are omitted.

- [x] **Step 3: Implement policies and visibility**

Organization owners/admins may manage campaigns, lists, templates, and launch;
organization members may read campaigns and rates as allowed by existing
Messaging policy conventions. Platform admins may inspect and perform
explicitly audited operational actions. Each policy defines `VISIBILITY` for
every action, with absent actions resolving to `[]` rather than an admin
bypass. The admin controllers expose campaign inspection, baseline-template
management, and volume-policy updates; volume-policy mutations require
`Idempotency-Key` and an audit record. Pause, Cancel, Abort, and Resume also
write request-bound transition audits with actor and reason evidence; exact
replays return the prior transition without duplicate effects.

- [x] **Step 4: Add Postman requests and examples**

Update `postman/Digis API_collection.json` with create/list/estimate/launch,
pause/cancel/abort, list import/status/report, template, analytics, inbound webhook, and
unsubscribe examples, plus admin campaign/template/volume-policy reads and
updates. Include `Idempotency-Key` headers, SMS segment quote response,
replay-safe launch response, 400 missing-key response, 409 conflict, and 401
invalid webhook signature examples.

- [x] **Step 5: Run API tests and route checks**

```bash
bin/rails test test/integration/messaging/campaigns_test.rb \
  test/integration/messaging/campaign_contact_lists_test.rb \
  test/integration/messaging/campaign_templates_test.rb \
  test/integration/messaging/campaign_contact_list_import_reports_test.rb \
  test/integration/admin/messaging/campaigns_test.rb
bin/rails routes | rg 'campaign|messaging/webhooks|messaging/unsubscribe'
```

Expected: authorization, safe serialization, pagination/filter/order,
idempotency, route, and Postman coverage pass.

- [ ] **Step 6: User-owned checkpoint**

```bash
git add app/controllers/messaging/campaign* \
  app/policies/messaging/campaign* \
  app/serializers/messaging/campaign* \
  config/routes.rb config/locales/messaging/campaigns.en.yml \
  postman/'Digis API_collection.json' test/integration/messaging/campaign* \
  test/integration/admin/messaging/campaigns_test.rb
git commit -m "feat(messaging): expose campaign organizer APIs"
```

## Task 11: Add recovery, retention, quotas, and recurring jobs

**Files:**
- Create: `app/jobs/messaging/reconcile_campaigns_job.rb` and
  `purge_campaign_payloads_job.rb`.
- Modify: `config/recurring.yml`, `config/queue.yml`, and locale files.
- Test: `test/jobs/messaging/process_scheduled_campaigns_job_test.rb`,
  `test/jobs/messaging/reconcile_campaigns_job_test.rb`, plus retention and
  quota cases in lifecycle tests.

- [x] **Step 1: Write recovery tests**

Cover stuck import rows, claimed deliveries past the five-minute lease,
paused/aborted cursor jobs, unresolved aggregate holds, terminal-delivery
completion recovery, canceled-hold finalization after in-flight settlement, and
retention erasure:

```ruby
test "reconciler requeues a stale delivery without duplicating allocation" do
  delivery = build_campaign_delivery(status: "processing", claimed_at: 6.minutes.ago)
  delivery.update_columns(claimed_at: 6.minutes.ago)
  Messaging::ReconcileCampaignsJob.perform_now
  assert_equal "pending", delivery.reload.status
  assert delivery.credit_allocation.present?
end

test "purge removes campaign message/contact material but keeps aggregate evidence" do
  campaign = build_campaign_with_rendered_message
  contact_entry = build_contact_entry_with_email
  campaign.update_columns(status: "completed", completed_at: 91.days.ago,
    updated_at: 91.days.ago)
  contact_entry.update_columns(created_at: 91.days.ago, updated_at: 91.days.ago)
  Messaging::PurgeCampaignPayloadsJob.perform_now
  assert_nil campaign.reload.message_body_ciphertext
  assert_nil contact_entry.reload.email_ciphertext
  assert Messaging::CreditReservation.exists?(
    source_type: "Messaging::Campaign", source_id: campaign.id
  )
end
```

- [x] **Step 2: Implement reconciliation and purge**

The reconciler claims bounded stale rows with `SKIP LOCKED`, replays existing
commands by ID, and never synthesizes provider success. Stale attempts on
terminal campaigns go through `RecoverCampaignDeliveryJob` with the original
delivery idempotency key; only never-attempted pending deliveries are refunded
as `campaign_aborted`. The purge job erases message bodies, materialized
recipient contact values, and import blobs after policy expiry while preserving
campaign status, quantities, rates, ledger entries, and aggregate analytics
required for reconciliation. Reusable active contact-list entries are retained;
removed entries and entries belonging to archived lists are purgeable. Its
candidate scope uses the explicit `PURGE_AFTER = 90.days` policy against
`completed_at`/`canceled_at`, so tests set a terminal status and timestamp at
least 91 days in the past before calling the job. Contact-entry and import-blob
sweeps are capped at 100 rows, lock with `SKIP LOCKED`, skip rows whose payload
is already absent, and advance the import timestamp after purge jobs are
scheduled so recurring runs do not revisit the same imports indefinitely.

- [x] **Step 3: Implement configurable volume policy**

`CampaignVolumePolicy` stores organization/channel daily and monthly limits.
Launch counts credit units (SMS segments or email recipients), rejects overage
with `campaign_volume_limit_exceeded`, and reports remaining quota in estimate
and launch responses. Admin updates are idempotent and audited.

- [x] **Step 4: Schedule jobs without queue contention**

Add campaign reconciliation every 10 minutes, import recovery every 10 minutes,
scheduled campaign processing every minute, and campaign purge at hour minute
20. Keep notification purge at minute 10 and
the existing core retention purge at minute 5. Retain the wildcard worker and
use `queue_as :notifications` for delivery/import jobs unless a measured queue
budget requires a separate queue.

- [x] **Step 5: Run job and configuration tests**

```bash
bin/rails test test/jobs/messaging/process_scheduled_campaigns_job_test.rb \
  test/jobs/messaging/reconcile_campaigns_job_test.rb
bin/rails runner 'abort "campaign recurring tasks missing" unless File.read(Rails.root.join("config/recurring.yml")).include?("process_scheduled_campaigns")'
bundle exec rubocop app/jobs/messaging config
```

Expected: recovery is bounded/idempotent and recurring configuration loads.

- [ ] **Step 6: User-owned checkpoint**

```bash
git add app/jobs/messaging/reconcile_campaigns_job.rb \
  app/jobs/messaging/purge_campaign_payloads_job.rb \
  config/recurring.yml config/queue.yml \
  test/jobs/messaging/reconcile_campaigns_job_test.rb
git commit -m "feat(messaging): add campaign recovery and retention jobs"
```

## Task 12: Add comprehensive preview fixtures and documentation

**Files:**
- Modify: `db/seeds/preview.rb`, `postman/Digis API_collection.json`, and
  `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md`.
- Create: `test/seeds_campaigns_test.rb` for campaign-specific convergence
  assertions.

- [x] **Step 1: Add safe seed scenarios**

Seed only synthetic data through commands: one SMS campaign with GSM-7 body,
one Amharic/emoji SMS quote, one Email campaign, one reusable list with valid,
duplicate, invalid, and suppressed rows, admin baseline templates, organizer
custom template, a checked-in and issued audience, and enough synthetic credits
for launch. Do not insert `delivered`, `consumed`, or terminal campaign states
by hand; invoke the real launch/settlement commands with fake adapters where
needed.

- [x] **Step 2: Add seed convergence tests**

Run the seed twice and assert one row per fixture identity, one list version,
one snapshot, one aggregate hold per launched fixture, no duplicate suppression,
and no duplicate ledger entries:

```bash
bin/rails test test/seeds_test.rb test/seeds_campaigns_test.rb
```

Expected: two runs converge with zero duplicate campaign, list, template,
snapshot, attestation, suppression, or credit evidence rows.

- [x] **Step 3: Update roadmap checkpoint**

Record the implementation plan path, selected product decisions, and the
remaining external provider-drill gate. Do not mark live SMS/email provider
delivery complete while adapters are still test doubles.

- [ ] **Step 4: User-owned checkpoint**

```bash
git add db/seeds/preview.rb test/seeds_campaigns_test.rb \
  postman/'Digis API_collection.json' \
  docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md
git commit -m "docs(messaging): add campaign fixtures and API examples"
```

## Task 13: Final acceptance gate

- [x] **Step 1: Run focused campaign/Messaging tests with N+1 detection**

```bash
N_PLUS_ONE=1 bin/rails test \
  test/models/messaging/campaign_schema_test.rb \
  test/models/messaging/campaign_test.rb \
  test/models/messaging/campaign_contact_list_test.rb \
  test/models/messaging/campaign_template_test.rb \
  test/models/messaging/campaign_suppression_test.rb \
  test/services/messaging/campaigns \
  test/services/messaging/credit_accounts \
  test/services/messaging/credit_rates \
  test/services/messaging/create_credit_top_up_test.rb \
  test/services/messaging/grant_top_up_credits_test.rb \
  test/services/messaging/resolve_top_up_payment_test.rb \
  test/services/messaging/outbox_handlers/campaign_launched_test.rb \
  test/services/messaging/providers/inbound_registry_test.rb \
  test/integration/messaging/credit_accounts_test.rb \
  test/integration/messaging/credit_top_ups_test.rb \
  test/integration/messaging/credit_rates_test.rb \
  test/jobs/messaging/import_campaign_contact_list_job_test.rb \
  test/jobs/messaging/prepare_campaign_audience_job_test.rb \
  test/jobs/messaging/fanout_campaign_job_test.rb \
  test/jobs/messaging/process_scheduled_campaigns_job_test.rb \
  test/jobs/messaging/reconcile_campaigns_job_test.rb \
  test/integration/messaging/campaigns_test.rb \
  test/integration/messaging/campaign_contact_lists_test.rb \
  test/integration/messaging/campaign_templates_test.rb \
  test/integration/messaging/campaign_contact_list_import_reports_test.rb \
  test/integration/messaging/campaign_unsubscribe_test.rb \
  test/integration/messaging/campaign_webhooks_test.rb \
  test/integration/admin/messaging/campaigns_test.rb \
  test/performance/messaging_campaign_fanout_test.rb
```

Expected: zero failures and zero errors, including SMS segment, aggregate-hold,
abort, unsubscribe, import, and replay cases.

- [x] **Step 2: Run quality, schema, and privacy gates**

```bash
bundle exec rubocop --parallel
bin/brakeman --quiet --no-pager
bin/rails zeitwerk:check
bin/rails db:schema:dump
git diff --check
```

Expected: RuboCop clean, Brakeman zero warnings, Zeitwerk reports “All is
good!”, structure dump is stable, and diff check is clean. Review Brakeman
output for encrypted-contact accessors, CSV parsing, redirect URLs, and webhook
signature handling.

- [x] **Step 3: Run the full suite and seed convergence**

```bash
N_PLUS_ONE=1 bin/rails test
bin/rails test test/seeds_test.rb test/seeds_campaigns_test.rb
```

Expected: zero failures/errors, existing skips explicitly reported, and two
seed runs converge.

- [x] **Step 4: Review the final diff against the spec**

Confirm:

- one channel per campaign and fixed SMS segment/email recipient units;
- `CreditRateVersion` remains the only price source;
- aggregate holds never call per-recipient reservation 10,000 times in HTTP;
- provider webhooks and email links share one suppression boundary;
- pause/abort releases unallocated hold and stops future cursors;
- links use existing `Links::ShortLink` custom URLs/UTM fields;
- no contact/message/provider secret leaks through jobs, outbox, logs,
  serializers, or Postman examples;
- no second wallet, second provider registry, or transactional inbox mixing;
- all routes, policies, serializer profiles, Ransack allowlists, migrations,
  indexes, seed fixtures, and Postman examples are present.

- [ ] **Step 5: User-owned final checkpoint**

Do not stage or commit automatically. Review the grouped commits, run any
authorized preview deployment/reset, and merge only after the acceptance gates
are green. Record the deployed commit and the remaining real-provider
SMS/email drill separately from local test evidence.

## Completion handoff

### Post-review hardening completed

- Due pending deliveries are claimed before fresh recipients; fan-out schedules
  retry jobs and completes campaigns only after all deliveries settle, finalizing
  the aggregate hold and releasing any remainder.
- Reconciliation updates stale rows inside the same `SKIP LOCKED` transaction and
  re-enqueues sending campaigns with due work.
- Organizer attestation and paused-campaign resume are exposed as idempotent API
  actions; unsubscribe GET remains read-only and POST performs suppression.
- Draft audience/content inputs clear quote evidence atomically, retention skips
  already-erased campaigns, analytics use grouped aggregates, contact imports use
  encrypted 500-row batches, and campaign link slugs bind campaign/name/destination.
- Allocation and settlement now share canonical identities and strict terminal
  replay behavior; estimate replays preserve the selected tier price and reject
  expired quotes. Channel addresses use one normalization seam, and inbound
  adapters provide provider-defined stop words with safe defaults.
- Final verification: full suite and focused campaign suite are green; RuboCop,
  Brakeman, Zeitwerk, Postman JSON, and `git diff --check` are clean.

After Task 13 is green and the user merges the grouped commits, update the
master roadmap to mark Marketing Campaigns implemented with any external
provider credentials/drills explicitly listed as pending. Do not start a second
campaign billing or notification pipeline; future work should extend the
existing adapter, suppression, credit, and link contracts.
