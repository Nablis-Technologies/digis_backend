# Campaign Hardening & Residuals Implementation Plan

Address the 5 verified residuals from the thermo-nuclear review pass on the Marketing Campaigns subsystem.

## Proposed Changes

### 1. Delivery Settlement Atomicity (`Deliver`)

Wrap `update_claimed` and `settle` in an enclosing `CampaignDelivery.transaction` block so delivery lease verification and credit settlement commit or rollback atomically.

#### [MODIFY] `app/services/messaging/campaigns/deliver.rb`
- In `finalize_outcome`: when `@settle` is true, wrap `update_claimed` and `settle` in `CampaignDelivery.transaction`.
- In `release_for_retry`: when `attempts >= MAX_ATTEMPTS` and `@settle` is true, wrap `update_claimed` and `settle` in `CampaignDelivery.transaction`.
- Ensures that if `update_claimed` raises `ClaimLost`, no ledger entries or allocations are touched. If `settle` fails, the delivery status update rolls back.

---

### 2. Deterministic Multi-Row Lock Ordering (`SettleBatch`)

Ensure deterministic lock acquisition in PostgreSQL across all three batch hierarchy levels.

#### [MODIFY] `app/services/messaging/campaigns/credit_holds/settle_batch.rb`
- Order `CampaignCreditAllocation` by `:id` before `.lock`.
- Order `CreditReservation` by `:id` before `.lock` (using `.uniq`).
- Order `CreditAccount` by `:id` before `.lock` (using `.uniq`).

```ruby
allocations = CampaignCreditAllocation.where(id: @outcomes.map(&:allocation).map(&:id)).order(:id).lock.index_by(&:id)
reservations = CreditReservation.where(id: allocations.values.map(&:credit_reservation_id).uniq).order(:id).lock.index_by(&:id)
accounts = CreditAccount.where(id: reservations.values.map(&:credit_account_id).uniq).order(:id).lock.index_by(&:id)
```

---

### 3. Reclaim Holds for Canceled and Failed Campaigns with Distinct Resolution Codes

Reclaim credit reservation holds for both `canceled` and `failed` terminal campaigns, tagging ledger entries with the exact domain reason.

#### [MODIFY] `app/jobs/messaging/reconcile_campaigns_job.rb`
- Rename `finalize_canceled_holds` to `finalize_terminal_holds` (and update call in `perform`).
- Query `Campaign.where(status: %w[canceled failed])`.
- Look up each campaign's terminal status to supply distinct resolution codes:
  - `"campaign_canceled"` when `campaign.status == "canceled"`
  - `"campaign_failed"` when `campaign.status == "failed"`

---

### 4. Remove Dead `idempotency_key` from `CreditHolds::Finalize`

`Finalize` is internally deterministic based on `[reservation.id, resolution_code]`. Remove the dead parameter and dead rescue block.

#### [MODIFY] `app/services/messaging/campaigns/credit_holds/finalize.rb`
- Remove `idempotency_key:` parameter from constructor.
- Remove `@raw_idempotency_key` and dead `rescue ArgumentError`.

#### [MODIFY] Callers of `CreditHolds::Finalize`
- `app/jobs/messaging/fanout_campaign_job.rb`
- `app/services/messaging/campaigns/abort.rb`
- `app/services/messaging/campaigns/cancel.rb`
- `app/jobs/messaging/reconcile_campaigns_job.rb`
- Corresponding tests in `test/services/messaging/campaigns/credit_holds_test.rb`.

---

### 5. Rename `Templates::AdminUpsert` to `Templates::Upsert`

Remove historical naming debt. The service handles both organizer-admin and platform-admin scoped templates.

#### [DELETE] `app/services/messaging/campaigns/templates/admin_upsert.rb`
#### [NEW] `app/services/messaging/campaigns/templates/upsert.rb`
- Rename class to `Messaging::Campaigns::Templates::Upsert`.

#### [MODIFY] Callers & Tests
- `app/controllers/messaging/campaign_templates_controller.rb`
- `app/controllers/admin/messaging/campaign_templates_controller.rb`
- Keep template command coverage in `test/services/messaging/campaigns/templates/upsert_test.rb`.

---

## Verification Plan

### Automated Tests
1. Run focused messaging campaign test suite:
   - `bin/rails test test/services/messaging/campaigns/`
   - `bin/rails test test/jobs/messaging/`
   - `bin/rails test test/integration/messaging/`
   - `bin/rails test test/models/messaging/`
2. Run full test suite:
   - `bin/rails test`
3. Static analysis & linting:
   - `bundle exec rubocop`
   - `bundle exec brakeman -q`
   - `bin/rails runner 'puts "Zeitwerk check passed"'`
