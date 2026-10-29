# Event-platform performance budgets

These budgets are launch review gates, not promises that every developer
laptop or shared CI runner will produce identical timings. Query-count checks
run in ordinary CI; wall-clock and scale tests run only with
`EVENT_PLATFORM_PERFORMANCE=1` on a fixed production-like machine class.

## Deterministic request budgets

| Surface | Fixture shape | Budget | Measurement |
| --- | --- | ---: | --- |
| Public event index | Default page, published public events, categories preloaded | ≤ 12 uncached SQL queries; query count must not grow with result count | `test/performance/public_event_catalog_test.rb` |
| Public event detail | One event, one cover, three gallery images, dates, categories, collaborators, and streams | ≤ 16 uncached SQL queries | `test/performance/public_event_catalog_test.rb` |
| Checkout creation | One buyer, one parking item, active Commercial definition, one quote token | ≤ 100 uncached SQL queries | `test/performance/order_checkout_test.rb` |
| Organizer attendee pagination | 50-row page with the maximum permitted export-visible associations | ≤ 25 uncached SQL queries | Add when the attendee report surface is included in the release candidate |

The query counter excludes schema, transaction, and cached SQL notifications.
`N_PLUS_ONE=1` remains enabled so Prosopite independently fails repeated
association access; the counter is not a replacement for N+1 detection.

## Opt-in throughput budgets

| Surface | Workload | Budget | Harness |
| --- | --- | ---: | --- |
| Scanner full snapshot serialization | 50,000 attendee-index entries | < 8 seconds on the production-like machine; < 12 seconds on CI | `test/performance/ticketing/scanner_sync_performance_test.rb` |
| Scanner upload serialization | 500 scan results | < 2 seconds | `test/performance/ticketing/scanner_sync_performance_test.rb` |
| Scanner delta serialization | 50,000 changed/tombstoned attendee-index entries | Same envelope as full snapshot; record p50/p95 before making it a release gate | `test/performance/ticketing/scanner_sync_performance_test.rb` |
| Webhook ingestion | 500 unique provider events, 20 duplicate retries, reverse arrival order | < 20 seconds locally; record p50/p95 on the fixed machine before tightening | `test/performance/webhook_ingestion_test.rb` |
| Reconciliation | One bounded supervisor cycle with each domain batch at 100 rows | 100 rows per domain job; no unbounded query or mutation loop | Existing reconciliation job batch constants |

The scanner limits are carried from the scanner contract fixture. The current
local opt-in run measured the 50,000-entry serializer and 500-result payload
within those limits, and the webhook harness completed its 520 requests in
approximately 2.3 seconds on the development machine. These observations are
not CI guarantees; repeat five warm runs and five cold-process runs on the
release machine and record p50/p95 before treating them as hard production
SLAs.

## Measurement protocol

- Runtime: Ruby 3.4.2, Rails 8.1.3.1, PostgreSQL, and the locked bundle.
- Query tests: warm application boot, transactional test database, uncached
  SQL notifications, and `N_PLUS_ONE=1`.
- Throughput tests: `EVENT_PLATFORM_PERFORMANCE=1`, one process, a fixed
  machine class, warm and cold-process samples, and p50/p95 over five runs.
- Record fixture counts, database size, PostgreSQL version, CPU/RAM, process
  workers, Ruby/Rails versions, and whether the run was warm or cold.
- Do not add wall-clock assertions to ordinary CI for environment-sensitive
  paths. A regression must first be reproduced on the fixed release machine.

## Index-plan review

Run:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner script/explain_event_platform_indexes
```

The script prints JSON summaries for public browse, inventory reservation,
checkout idempotency, admission first-scan, credential-revocation delta,
settlement ledger, and active resale-listing queries. With
`EVENT_PLATFORM_PERFORMANCE=1`, it fails the release review if a plan has a
sequential scan over more than 1,000 actual rows. Empty or development-sized
tables may legitimately show sequential scans; those are evidence to repeat
the review against production-like data, not automatic CI failures.
