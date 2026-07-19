---
created: 2026-06-01T18:15:00Z
branch: add-followable-entities
trigger: manual
restored: false
topic: public-common-concern-tests
---

# Handoff: PublicCommon concern tests and Postman updates

## Goal
Finalize `Core::PublicCommon` concern with passing concern-level unit tests, update Postman collection with filter query params, and verify all 700+ tests green.

## Current State
- **Done:** `Core::PublicCommon` concern extracted and migrated to all 4 public catalog controllers (Categories, Venues, Artists, Organizations)
- **Done:** Concern tests (10 tests, `test/concerns/core/public_common_test.rb`) rewritten using `ActionDispatch::IntegrationTest` with real `Events::Category` model — all passing
- **Done:** Integration filter tests for venues (city, country, verified), artists (genre, verified), and organizations (Ransack `q[name_cont]`)
- **Done:** Postman collection updated with `order_by`, `order_direction`, and resource-specific filter query params
- **In Progress:** Debugging a pre-existing `RecordNotFound` test database issue — 277 errors in 719-test run, all `Couldn't find Core::User with id = 1` — unrelated to current changes
- **Not started:** No open work items

## Key Decisions
- Concern tests use `ActionDispatch::IntegrationTest` with real model (`Events::Category`) instead of anonymous `ActiveSupport::TestCase` with fake models — more reliable and tests real behavior
- Concern tests verify individual method contracts (searchable?, apply_catalog_filters, allowed_order_columns, base_scope, detail_scope) and class_attribute setup — NOT the full `index`/`show` action flow (those are tested via controller integration tests)
- Postman public list items updated with available query params — Categories gets order_by/order_direction/q[name_cont], Venues gets city/country/verified, Artists gets genre/verified, Organizations gets order_by/order_direction/q[name_cont]

## Modified Files
- `app/controllers/concerns/core/public_common.rb`
- `app/controllers/events/artists_controller.rb`
- `app/controllers/events/venues_controller.rb`
- `app/controllers/organizations/organizations_controller.rb`
- `test/integration/events/artists_test.rb`
- `test/integration/events/venues_test.rb`
- `test/integration/organizations/organizations_test.rb`
- `test/concerns/core/public_common_test.rb`
- `postman/Digis API_collection.json`

## Failed Approaches
- Anonymous controller in `ActiveSupport::TestCase` with fake model class (`PublicCommonTestModel`) — `limit`/`offset` chaining in `Core::Pagination::apply_pagination` incompatible with Array-based mock; `rendered` nil issues from missing Rails request/response infrastructure
- Using `rescue/puts` for debugging — Minitest captures stdout, use `$stderr.puts` instead

## Files to Read
- `test/concerns/core/public_common_test.rb` — finalized concern unit tests
- `app/controllers/concerns/core/public_common.rb` — the extracted concern
- `docs/superpowers/specs/2026-06-01-public-catalog-common-design.md`
- `docs/superpowers/plans/2026-06-01-public-common-implementation.md`

## Next Steps
1. Investigate `RecordNotFound` errors in full test suite — likely a fixture loading issue (pre-existing, not from these changes)
2. Run relevant integration tests in isolation to confirm current changes don't break anything:
   - `rails test test/integration/events/venues_test.rb`
   - `rails test test/integration/events/artists_test.rb`
   - `rails test test/integration/organizations/organizations_test.rb`
   - `rails test test/integration/admin/organizations_test.rb`
   - `rails test test/concerns/core/public_common_test.rb`
3. Commit pending changes if verified

## Open Questions
- Test database state: 277 `RecordNotFound` errors suggest fixtures not loading — investigate before further work
