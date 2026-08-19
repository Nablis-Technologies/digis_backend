# Backup, restore, and disaster recovery

## Operating boundary

- Owner: Platform infrastructure on-call with Finance, Payments, and Ticketing
  incident owners.
- Severity: SEV-1 for primary database loss or corruption.
- Authority: Only the infrastructure/change authority may restore or fail over
  a production database. Finance and Ticketing approve business verification
  before traffic is reopened.

## Detect

Use the provider database health signal, Rails readiness result, migration
errors, checksum/backup verification, outbox age, and reconciliation drift.
`/up` proves process liveness; `/admin/system/readiness` proves authenticated
local dependency readiness without exposing credentials.

## Immediate action

1. Declare the incident and freeze deploys, destructive maintenance, payout
   dispatch, and customer-facing state changes unless the incident commander
   explicitly authorizes them.
2. Preserve the last known database endpoint, backup identifier, migration
   version, application release, and secret/configuration version.
3. Prefer provider-native point-in-time recovery or failover. Restore into an
   isolated database first when the primary is still available.
4. Keep provider incident evidence and application logs; do not discard inbox,
   outbox, payment, refund, payout, credential, or audit rows.

## Prohibited action

- Never run `DROP DATABASE`, `pg_restore --clean`, or schema rewrites against
  the live database without an approved change and verified rollback.
- Never repair financial, ticket, revocation, or outbox state with direct SQL.
- Never reopen traffic before provider reconciliation and scanner-version
  checks complete.

## Backup and isolated-restore procedure

Use a secret-manager or provider-generated connection URL; never paste a
password into shell history. The following commands target an isolated restore
database only:

```bash
pg_dump --format=custom --file=digis-backend-$(date -u +%Y%m%dT%H%M%SZ).dump "$SOURCE_DATABASE_URL"
createdb "$RESTORE_DATABASE_NAME"
pg_restore --exit-on-error --no-owner --dbname="$RESTORE_DATABASE_URL" \
  "$BACKUP_FILE"
```

Verify the restored database through Rails before any cutover:

```bash
RENDER_PREVIEW=true RENDER_PREVIEW_DATABASE_URL="$RESTORE_DATABASE_URL" \
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
puts Admin::System::Readiness.call.value.inspect
puts Core::OutboxEvent.where(published_at: nil).count
puts Orders::PaymentEvent.where(status: %w[received processing failed]).count
'
```

## Recovery

After infrastructure approves the restored endpoint and the application is
booting against it:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Core::ProcessOutboxJob.perform_now'
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner \
  'Reconciliation::SupervisorJob.perform_now("all")'
```

Then verify provider payment/refund events, organizer payouts, seller payouts,
credential projections, revocation versions, and readiness. Reopen traffic in
stages; high-security gates remain online-required until scanner sync is
confirmed.

## Communication and verification

Infrastructure owns service-status communication. Payments/Finance own money
reconciliation notices, Ticketing owns scanner/gate notices, and Support owns
attendee communication. Record backup ID, restore target, release/configuration
versions, readiness output, reconciliation job IDs, provider confirmations, and
the incident commander approval before closing.

## Staging drill

Restore a recent backup into an isolated database, boot the application against
it, process the outbox, run reconciliation, and verify readiness. Simulate one
duplicate provider event and one stale scanner cursor. Confirm idempotent
recovery, preserved immutable history, and a documented cutover/rollback
decision without touching the live database.
