# Campaign Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the verified campaign retention, idempotency, replay, query-loading, quota, recovery, and association gaps without guessing an ambiguous provider result.

**Architecture:** Keep reusable contact-list data durable while purging only removed entries or archived lists. Route organizer template mutations through the same audit-backed command boundary as administrative templates. Recover stale provider calls with their original delivery idempotency key, while refunding only deliveries that were never attempted; active campaigns continue through the existing fan-out path.

**Tech Stack:** Rails 8.1, Active Record, Minitest, Active Job, PostgreSQL, Core idempotency/audit services.

**Status:** Implemented and verified on 2026-09-07; no changes were staged or committed.

---

### Task 1: Protect active organizer contact lists from retention erasure

**Files:**
- Modify: `app/jobs/messaging/purge_campaign_payloads_job.rb`
- Modify: `test/jobs/messaging/reconcile_campaigns_job_test.rb`

- [ ] **Step 1: Write failing retention tests**

Add a test proving an old entry in an active list remains encrypted, and change the existing batch fixture to use a removed entry or archived list. Add coverage that an old removed entry is still erased.

- [ ] **Step 2: Run the retention tests and verify the active-entry failure**

Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/messaging/reconcile_campaigns_job_test.rb`. The active-entry preservation assertion must fail against the current purge query.

- [ ] **Step 3: Restrict purge candidates to removed entries or archived lists**

Join `Messaging::CampaignContactList` and qualify the entry table in the age predicate. The candidate relation must require:

```ruby
CampaignContactListEntry.joins(:campaign_contact_list)
  .where("messaging_campaign_contact_list_entries.updated_at <= ?", cutoff)
  .where(
    "messaging_campaign_contact_list_entries.status = :removed OR messaging_campaign_contact_lists.status = :archived",
    removed: "removed", archived: "archived"
  )
```

Keep the existing bounded `FOR UPDATE SKIP LOCKED` update.

- [ ] **Step 4: Run the retention tests and confirm both cases pass**

Run the same test file; expect active entries preserved and removed/archived entries erased.

### Task 2: Reconcile stale deliveries without orphaning or guessing

**Files:**
- Create: `app/jobs/messaging/recover_campaign_delivery_job.rb`
- Modify: `app/jobs/messaging/reconcile_campaigns_job.rb`
- Modify: `test/jobs/messaging/reconcile_campaigns_job_test.rb`

- [ ] **Step 1: Write failing recovery tests**

Add tests for: active stale deliveries becoming pending; canceled stale deliveries being handed to a recovery job instead of reset and orphaned; a canceled delivery with zero provider attempts being settled as failed/refunded; and a recovery job using the existing delivery idempotency key to settle a successful provider result.

- [ ] **Step 2: Run the recovery tests and verify the new behavior is absent**

Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/messaging/reconcile_campaigns_job_test.rb`. The terminal-campaign recovery assertions must fail before implementation.

- [ ] **Step 3: Add an ID-only recovery job**

Implement `Messaging::RecoverCampaignDeliveryJob` on the `notifications` queue. It loads one delivery, calls `Campaigns::Deliver.call(delivery_id:)`, raises typed failures for Active Job retry, and schedules itself at `next_attempt_at` when the delivery remains pending. Missing deliveries are harmless.

- [ ] **Step 4: Split active reclaim from terminal recovery**

In `ReconcileCampaignsJob`, lock the campaign before the delivery when classifying stale rows. Reset stale work to pending only for non-terminal campaigns. For canceled/completed/failed campaigns, keep the delivery claim eligible for `Deliver` and enqueue `RecoverCampaignDeliveryJob` with the delivery ID. Add a bounded query for terminal pending deliveries with `attempts > 0` and an allocated credit row so missed recovery-job scheduling is retried.

- [ ] **Step 5: Release only never-attempted canceled deliveries**

Before finalizing canceled holds, settle terminal-campaign pending deliveries with `attempts = 0` and allocated credits as `failed` using `campaign_aborted` evidence. Do not settle deliveries with provider attempts; those must go through the recovery job and the provider’s idempotency contract.

- [ ] **Step 6: Run recovery tests and the focused campaign suite**

Run the reconciliation test file and the campaign lifecycle/delivery tests. Expect all recovery cases to pass without changing active fan-out behavior.

### Task 3: Make organizer template mutations audit-backed and replay-safe

**Files:**
- Modify: `app/services/messaging/campaigns/templates/upsert.rb`
- Modify: `app/controllers/messaging/campaign_templates_controller.rb`
- Modify: `config/locales/messaging/campaigns.en.yml`
- Modify: `test/integration/messaging/campaign_templates_test.rb`
- Modify: `test/integration/admin/messaging/campaigns_test.rb`

- [ ] **Step 1: Write failing organizer replay/conflict tests**

Add integration tests asserting the same organizer create request and key creates one row and returns the original row, while reusing the key with different content returns `idempotency_conflict`. Add a duplicate-name/different-key case asserting a typed conflict rather than 422/500.

- [ ] **Step 2: Run the template tests and verify duplicate side effects**

Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/messaging/campaign_templates_test.rb test/integration/admin/messaging/campaigns_test.rb`. The organizer replay must currently create or conflict incorrectly.

- [ ] **Step 3: Parameterize the existing upsert command by organization**

Allow `Templates::Upsert` to receive `organization:`. Include `organization_id` in the canonical request digest, authorize organization admins for organizer targets, preserve `organization: nil` for global admin templates, and assign the target organization during persistence. Map uniqueness violations to a localized typed template-name conflict.

- [ ] **Step 4: Delegate organizer create/update to the command**

Replace direct `save` and `update` calls in `CampaignTemplatesController` with `Templates::Upsert.call` using the current organization and action. Keep the existing serializer and HTTP statuses.

- [ ] **Step 5: Run both template integration suites**

Expect audit-backed replay, conflict detection, authorization, and global admin behavior to pass.

### Task 4: Make launch replay terminal-state safe

**Files:**
- Modify: `app/services/messaging/campaigns/launch.rb`
- Modify: `test/services/messaging/campaigns/lifecycle_test.rb`

- [ ] **Step 1: Add a failing completed-launch replay test**

Launch a small campaign, complete it, then replay the original request/key and assert success with the completed campaign instead of `campaign_invalid_state`.

- [ ] **Step 2: Move matching-key replay before transient status gating**

When a campaign has a launch hold and its stored launch-key digest matches, validate the supplied quote identity and return the campaign regardless of whether it is scheduled, sending, paused, completed, or canceled. Preserve conflict behavior for a different key or mismatched quote.

- [ ] **Step 3: Run lifecycle tests**

Run the lifecycle test file and verify the original launch, completed replay, stale quote, and conflicting-key cases.

### Task 5: Correct delivery preloading and quota windows

**Files:**
- Modify: `app/services/messaging/campaigns/deliver.rb`
- Modify: `app/services/messaging/campaigns/quota.rb`
- Modify: `test/services/messaging/campaigns/deliver_test.rb`
- Modify: `test/services/messaging/campaigns/lifecycle_test.rb`

- [ ] **Step 1: Add regression tests**

Add a delivery test that loads by `delivery_id` and asserts the direct allocation association is already loaded before settlement. Add a quota boundary test where the quote is before midnight and launch is after midnight; count the units in the launch window.

- [ ] **Step 2: Implement direct allocation eager loading**

Change the `Deliver` relation to include `{ campaign: %i[organization event] }, :campaign_recipient, :credit_allocation` and remove the circular recipient-to-delivery traversal.

- [ ] **Step 3: Window quota usage by `launched_at`**

Keep the launched-at-not-null filter and replace the `quoted_at` range with `launched_at: start_time..end_time`.

- [ ] **Step 4: Run delivery and lifecycle tests**

Expect no extra lazy load in the delivery path and correct day/month launch accounting.

### Task 6: Harden batch allocation and model associations

**Files:**
- Modify: `app/services/messaging/campaigns/credit_holds/allocate_batch.rb`
- Modify: `app/models/messaging/campaign.rb`
- Modify: `app/models/messaging/campaign_audience_snapshot.rb`
- Modify: `test/services/messaging/campaigns/credit_holds_test.rb`
- Modify: `test/models/messaging/campaign_test.rb`

- [ ] **Step 1: Add empty-batch and association tests**

Assert an empty `AllocateBatch` request returns success without creating rows or requiring a hold balance calculation. Assert the new campaign and snapshot collections expose attestations and campaign credit allocations with the expected class and inverse behavior.

- [ ] **Step 2: Add the empty-batch guard**

Return `success(true)` immediately after calculating `pending` when it is empty, before quantity checks or insert SQL.

- [ ] **Step 3: Add inverse associations**

Declare `Campaign#attestations`, `Campaign#credit_allocations`, and `CampaignAudienceSnapshot#attestations` with the existing names, foreign keys, inverses where supported, and dependent behavior consistent with the database cascades.

- [ ] **Step 4: Run the focused model/hold tests**

Run the new model and credit-hold tests and confirm no association or allocation regressions.

### Task 7: Full verification and documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-09-05-marketing-campaigns-design.md`
- Modify: `docs/superpowers/plans/2026-09-06-marketing-campaigns-implementation.md`

- [ ] **Step 1: Document retention and terminal-delivery recovery policy**

State that reusable active contact lists are durable, removed/archived contact material is purgeable, never-attempted canceled deliveries are refunded, and provider-attempted deliveries are retried with the original idempotency key until a provider-neutral result is available.

- [ ] **Step 2: Run all gates**

Run the full Rails suite, RuboCop, Brakeman, Zeitwerk, Postman JSON parsing, and `git diff --check`. Report exact counts and any intentional skips.
