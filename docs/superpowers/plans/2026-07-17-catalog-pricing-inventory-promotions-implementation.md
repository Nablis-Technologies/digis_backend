# Catalog, Pricing, Inventory, and Promotions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a composable event catalog supporting ticket and add-on products, package ticket policies, multi-currency prices, FX quotes, concurrency-safe inventory/capacity, venue and parking access zones, multi-date refund allocations, invitations, access codes, and one minimal non-stackable buyer promotion.

**Architecture:** Products are the commerce seam; only ticket products receive a one-to-one ticket type. Catalog mutations use ordinary `Core::Common` CRUD only while the product is an unsold draft; activation, access replacement, inventory reservation, FX/promotion quoting, and immutable-policy transitions each use one `Core::BaseService` command. PostgreSQL locks and constraints prevent overselling, overlapping prices, and invalid cross-event grants. The later orders plan owns promotion redemption reservations because their aggregate and foreign keys belong to checkout.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs and range/exclusion constraints, Pundit, ActiveModelSerializers, Solid Queue, Minitest fixtures.

---

## Normative sources and delivery rules

- Implement sections 7, 8.1-8.3, 13, 14, 17, and Phase 2 of `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`; preserve the stable access-ID and package semantics in `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`.
- This is pre-launch development: migrate directly to the approved schema and delete superseded development structures. Do not dual write or preserve inferior interfaces.
- Reuse event settings/dates/access zones, `Core::BaseService`, policy visibility, audit/outbox, and current identity. Do not create a pricing rules engine, promotion stacking, seat maps, or a second permission system.
- Reuse Plan 0 `Core::Money` for integer amount/currency validation and arithmetic, `Core::IdempotencyKey` for command keys, and `Core::Database::AdvisoryLock` wherever transaction-scoped logical serialization is required. Keep `Catalog::PriceQuote` domain-specific because it snapshots price-source and FX evidence. Provider capability lookup remains a focused catalog query, not a general adapter framework in this phase.
- Every business `type` model disables STI and receives a regression test.
- All monetary values are integer minor units, ISO 4217 codes, and `BigDecimal` FX rates. No float enters calculation or persistence.
- Commands run with `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test ...`.

## File map

**Create migrations**

- `db/migrate/20260717020100_create_catalog_event_products_and_ticket_types.rb`
- `db/migrate/20260717020200_create_catalog_product_prices_and_exchange_rates.rb`
- `db/migrate/20260717020300_create_catalog_inventory.rb`
- `db/migrate/20260717020400_create_catalog_product_accesses_and_allocations.rb`
- `db/migrate/20260717020500_create_catalog_promotions.rb`
- `db/migrate/20260717020600_create_ticketing_access_codes_and_invitations.rb`
- `db/migrate/20260717020800_create_event_consent_document_products.rb`

**Create models**

- `app/models/catalog/event_product.rb`, `product_price.rb`, `exchange_rate.rb`, `product_inventory.rb`, `inventory_reservation.rb`, `product_access.rb`, `product_access_zone.rb`, `product_date_allocation.rb`, `promotion.rb`, `promotion_code.rb`, `promotion_product.rb`
- `app/models/ticketing/ticket_type.rb`, `access_code.rb`, `invitation.rb`; reuse Plan 0 `Ticketing::ApplicationRecord`
- `app/models/events/consent_document_product.rb`

**Create controllers/policies/serializers**

- `app/controllers/catalog/event_products_controller.rb`, `product_prices_controller.rb`, `product_inventories_controller.rb`, `product_accesses_controller.rb`, `product_date_allocations_controller.rb`, `promotions_controller.rb`, `promotion_codes_controller.rb`, `product_quotes_controller.rb`
- `app/controllers/ticketing/ticket_types_controller.rb`, `access_codes_controller.rb`, `invitations_controller.rb`, `audience_authorizations_controller.rb`
- `app/policies/catalog/event_product_policy.rb`, `promotion_policy.rb`, `product_inventory_policy.rb`
- `app/policies/ticketing/ticket_type_policy.rb`, `access_code_policy.rb`, `invitation_policy.rb`
- `app/serializers/catalog/event_product_serializer.rb`, `product_price_serializer.rb`, `product_inventory_serializer.rb`, `promotion_serializer.rb`, `product_quote_serializer.rb`
- `app/serializers/catalog/public/event_product_serializer.rb`
- `app/serializers/ticketing/ticket_type_serializer.rb`, `invitation_serializer.rb`

**Create services/jobs/value objects**

- `app/services/catalog/products/create.rb`, `activate.rb`, `deactivate.rb`
- `app/services/catalog/pricing/quote.rb`, `create_price.rb`, `currency_compatibility.rb`
- `app/services/catalog/exchange_rates/record.rb`
- `app/services/catalog/inventory/reserve.rb`, `commit.rb`, `release.rb`, `expire.rb`, `reconcile.rb`
- `app/services/catalog/accesses/replace.rb`, `zones/replace_grants.rb`, `date_allocations/replace.rb`
- `app/services/catalog/promotions/create.rb`, `publish_version.rb`, `disable.rb`, `quote.rb`
- `app/services/ticketing/audience/authorize.rb`, `access_codes/consume.rb`, `invitations/claim.rb`
- `app/services/events/consent_documents/replace_scope.rb`
- `app/jobs/catalog/refresh_exchange_rates_job.rb`, `expire_inventory_reservations_job.rb`, `reconcile_inventory_job.rb`
- `app/jobs/ticketing/deliver_invitation_job.rb`, `expire_invitations_job.rb`
- `app/values/catalog/price_quote.rb`

**Modify**

- `config/routes.rb`
- `config/recurring.yml`
- `config/initializers/filter_parameter_logging.rb`
- `config/initializers/catalog_outbox_handlers.rb`

**Create tests/fixtures**

- Model tests under `test/models/catalog/` and `test/models/ticketing/`
- Service tests under `test/services/catalog/` and `test/services/ticketing/`
- Integration tests under `test/integration/catalog/` and `test/integration/ticketing/`
- Job tests under `test/jobs/catalog/`, `test/jobs/ticketing/`
- Fixtures matching every exact table above under `test/fixtures/`

## Task 1: Add products, ticket-package policies, access codes, and invitations

**Files:**
- Create: `db/migrate/20260717020100_create_catalog_event_products_and_ticket_types.rb`
- Create: `db/migrate/20260717020600_create_ticketing_access_codes_and_invitations.rb`
- Create: `db/migrate/20260717020800_create_event_consent_document_products.rb`
- Create: `app/models/catalog/event_product.rb`
- Create: `app/models/ticketing/ticket_type.rb`, `access_code.rb`, `invitation.rb`
- Reuse: `app/models/ticketing/application_record.rb` from the Plan 0 core foundation
- Create: `app/models/events/consent_document_product.rb`
- Create: `app/services/catalog/products/create.rb`, `activate.rb`, `deactivate.rb`
- Create: `app/services/ticketing/audience/authorize.rb`, `access_codes/consume.rb`, `invitations/claim.rb`
- Create: `app/services/events/consent_documents/replace_scope.rb`
- Test: `test/models/catalog/event_product_test.rb`
- Test: `test/models/ticketing/ticket_type_test.rb`
- Test: `test/services/ticketing/audience/authorize_test.rb`
- Test: `test/services/events/consent_documents/replace_scope_test.rb`

- [ ] **RED:** test the exact product type allowlist, positive ordered quantity limits, one ticket type only for ticket products, audience/approval/date-selection states, package-size immutability after first registration/hold/item, transfer/delegation/ID/resale field checks, digest uniqueness, access-code quantity/use limits, invitation encrypted contact/token state, STI opt-out, unique consent-document/ticket-type scope, and same-event scope enforcement.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/event_product_test.rb test/models/ticketing/ticket_type_test.rb test/services/ticketing/audience/authorize_test.rb test/services/events/consent_documents/replace_scope_test.rb`; expect missing schema/classes.
- [ ] **GREEN:** implement exact tables `catalog_event_products`, `ticketing_ticket_types`, `ticketing_access_codes`, `ticketing_invitations`, and `events_consent_document_products`; use one service to create a product and required ticket-type row atomically. `Events::ConsentDocuments::ReplaceScope` locks the document and replaces unique same-event ticket-type scopes. Hash normalized codes with an event-namespaced keyed digest and filter all raw token/code params from logs.

```ruby
# app/services/ticketing/audience/authorize.rb
module Ticketing
  module Audience
    class Authorize < Core::BaseService
      def initialize(ticket_type:, user:, access_code: nil, invitation_token: nil)
        @ticket_type = ticket_type
        @user = user
        @access_code = access_code
        @invitation_token = invitation_token
      end

      def call
        case ticket_type.audience
        when "public" then success
        when "access_code" then authorize_code
        when "invitation" then authorize_invitation
        when "code_or_invitation" then authorize_code.success? ? success : authorize_invitation
        else
          failure Core::BusinessError.new(
            "Unsupported ticket audience",
            code: "unsupported_audience",
            status: :unprocessable_entity
          )
        end
      end

      private

      attr_reader :ticket_type, :user, :access_code, :invitation_token

      def authorize_code
        AccessCodes::Consume.call(ticket_type:, plaintext_code: access_code, consume: false)
      end

      def authorize_invitation
        Invitations::Claim.call(ticket_type:, token: invitation_token, user:, preview: true)
      end
    end
  end
end
```

- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/event_product_test.rb test/models/ticketing/ticket_type_test.rb test/services/ticketing/audience/authorize_test.rb test/services/events/consent_documents/replace_scope_test.rb`; expect pass.
- [ ] **Refactor:** keep promo codes separate from audience authorization. Ensure no public serializer exposes access-code digests, invitation contacts, tokens, inventory counters, or resale internals.
- [ ] **Commit:** stage listed files and fixtures, then commit `feat(catalog): add products and ticket audience policies`.

## Task 2: Add multi-currency prices, exchange rates, and deterministic quotes

**Files:**
- Create: `db/migrate/20260717020200_create_catalog_product_prices_and_exchange_rates.rb`
- Create: `app/models/catalog/product_price.rb`, `exchange_rate.rb`
- Create: `app/values/catalog/price_quote.rb`
- Reuse: `app/lib/core/money.rb` from the Plan 0 core foundation
- Create: `app/services/catalog/pricing/create_price.rb`, `quote.rb`, `currency_compatibility.rb`
- Create: `app/services/catalog/exchange_rates/record.rb`
- Create: `app/controllers/catalog/product_prices_controller.rb`, `product_quotes_controller.rb`
- Create: `app/serializers/catalog/product_price_serializer.rb`, `product_quote_serializer.rb`
- Create: `app/jobs/catalog/refresh_exchange_rates_job.rb`
- Test: `test/models/catalog/product_price_test.rb`
- Test: `test/services/catalog/pricing/quote_test.rb`
- Test: `test/integration/catalog/product_quotes_test.rb`

- [ ] **RED:** test one active base price/window, no overlapping active ranges for product/type/currency, zero price, ISO currencies, positive non-float rates, expiry, fixed override preference, half-up conversion, unsupported charge currency, and immutable quote evidence.

```ruby
# test/services/catalog/pricing/quote_test.rb
require "test_helper"

class Catalog::Pricing::QuoteTest < ActiveSupport::TestCase
  test "uses an active fixed override before exchange conversion" do
    product = catalog_event_products(:festival_pass)

    result = Catalog::Pricing::Quote.call(product:, charge_currency: "USD", at: Time.current)

    assert result.success?, result.error.inspect
    quote = result.value
    assert_equal "USD", quote.charge_currency
    assert_equal 2_500, quote.amount_minor
    assert_equal "override", quote.source_type
    assert_nil quote.exchange_rate
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/product_price_test.rb test/services/catalog/pricing/quote_test.rb test/integration/catalog/product_quotes_test.rb`; expect missing price/quote code.
- [ ] **GREEN:** use PostgreSQL range exclusion for overlapping active windows, `decimal(24,12)` rates, an immutable `Catalog::PriceQuote = Data.define(...)`, Plan 0 `Core::Money`, and currency-specific minor-unit rounding. The quote endpoint reads only; order creation later persists its evidence.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog/product_price_test.rb test/services/catalog/pricing/quote_test.rb test/integration/catalog/product_quotes_test.rb`; expect pass.
- [ ] **Refactor:** keep all generic amount/currency behavior in Plan 0 `Core::Money`; `Catalog::PriceQuote` contains only catalog-specific source, amount, currency, and FX evidence and does not become accounting or gateway policy.
- [ ] **Commit:** stage listed files and commit `feat(catalog): add multi-currency price quoting`.

## Task 3: Add inventory reservation, venue capacity, expiry, and reconciliation

This task owns the exact `catalog_product_inventories` and `catalog_inventory_reservations` tables from Sections 7.4–7.5 of the database design.

**Files:**
- Create: `db/migrate/20260717020300_create_catalog_inventory.rb`
- Create: `app/models/catalog/product_inventory.rb`, `inventory_reservation.rb`
- Create: `app/services/catalog/inventory/reserve.rb`, `commit.rb`, `release.rb`, `expire.rb`, `reconcile.rb`
- Create: `app/controllers/catalog/product_inventories_controller.rb`
- Create: `app/policies/catalog/product_inventory_policy.rb`
- Create: `app/serializers/catalog/product_inventory_serializer.rb`
- Create: `app/jobs/catalog/expire_inventory_reservations_job.rb`, `reconcile_inventory_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/services/catalog/inventory/reserve_test.rb`
- Test: `test/services/catalog/inventory/lifecycle_test.rb`
- Test: `test/jobs/catalog/reconcile_inventory_job_test.rb`

- [ ] **RED:** test nonnegative/capped counters, null-date and dated uniqueness, owner XOR registration/order item, package-vs-people units, deterministic multi-pool locking, concurrent final capacity, atomic rollback, idempotent commit/release/expire, and reconciliation detecting but not hiding drift.

```ruby
# app/services/catalog/inventory/reserve.rb public interface expected by the tests
result = Catalog::Inventory::Reserve.call(
  product:,
  event_date_ids:,
  package_quantity: 2,
  admissions_per_unit: 3,
  owner: registration,
  reservation_group_id: command_id,
  expires_at: 10.minutes.from_now
)
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/inventory/reserve_test.rb test/services/catalog/inventory/lifecycle_test.rb test/jobs/catalog/reconcile_inventory_job_test.rb`; expect missing schema/service.
- [ ] **GREEN:** lock inventory rows by UUID order, then applicable event-date rows by UUID order; validate all pools; insert reservations and update every held counter in one transaction. `processing` continues to count as held. Commit moves held to sold and date held to issued; release/expiry reverses only once.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/inventory/reserve_test.rb test/services/catalog/inventory/lifecycle_test.rb test/jobs/catalog/reconcile_inventory_job_test.rb`; expect the thread/barrier transaction test to produce exactly one winner for the final unit.
- [ ] **Refactor:** keep the lock-order helper local to Catalog until at least three non-inventory consumers require it. Never expose raw counters publicly.
- [ ] **Commit:** stage listed files and commit `feat(catalog): add concurrency-safe inventory reservations`.

## Task 4: Add immutable product access, zone grants, and multi-date value allocations

**Files:**
- Create: `db/migrate/20260717020400_create_catalog_product_accesses_and_allocations.rb`
- Create: `app/models/catalog/product_access.rb`, `product_access_zone.rb`, `product_date_allocation.rb`
- Create: `app/services/catalog/accesses/replace.rb`, `zones/replace_grants.rb`, `date_allocations/replace.rb`
- Create: `app/controllers/catalog/product_accesses_controller.rb`, `product_date_allocations_controller.rb`
- Test: `test/services/catalog/accesses/replace_test.rb`
- Test: `test/services/catalog/date_allocations/replace_test.rb`
- Test: `test/models/catalog/product_access_zone_test.rb`

- [ ] **RED:** cover unique product/date/type, relative access windows, explicit single/bounded/unlimited usage, same-event product/date, required `public`/`soft_gated`/`signed` protection only for stream access, venue/parking protection nullability, venue/parking zone same date/type, stream-zone prohibition, explicit grants whenever zones active, allocation coverage and deferred 10,000 basis-point sum, and access/allocation freeze on first hold.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/accesses/replace_test.rb test/services/catalog/date_allocations/replace_test.rb test/models/catalog/product_access_zone_test.rb`; expect missing tables/services.
- [ ] **GREEN:** create exact tables `catalog_product_accesses`, `catalog_product_access_zones`, and `catalog_product_date_allocations`. Add `required_access_protection` with the exact stream-only check and protection ordering defined by the architecture. Use a deferred PostgreSQL constraint trigger for the 10,000 sum and service validation for actionable errors. Replace draft access/grants in one locked transaction; reject mutation after any reservation/order dependency.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/accesses/replace_test.rb test/services/catalog/date_allocations/replace_test.rb test/models/catalog/product_access_zone_test.rb`; expect pass.
- [ ] **Refactor:** accesses describe rights; date allocations describe value. Do not duplicate venue/stream/parking rights in allocation rows or absolute schedule timestamps in access rows.
- [ ] **Commit:** stage listed files and commit `feat(catalog): add product access and date allocations`.

## Task 5: Implement minimal non-stackable promotion definitions and quote contract

This task owns `catalog_promotions`, `catalog_promotion_codes`, and `catalog_promotion_products`. The later orders plan alone owns `orders_promotion_redemptions`.

**Files:**
- Create: `db/migrate/20260717020500_create_catalog_promotions.rb`
- Create: `app/models/catalog/promotion.rb`, `promotion_code.rb`, `promotion_product.rb`
- Create: `app/services/catalog/promotions/create.rb`, `publish_version.rb`, `disable.rb`, `quote.rb`
- Create: `app/controllers/catalog/promotions_controller.rb`, `promotion_codes_controller.rb`
- Create: `app/policies/catalog/promotion_policy.rb`
- Create: `app/serializers/catalog/promotion_serializer.rb`
- Test: `test/services/catalog/promotions/quote_test.rb`
- Test: `test/integration/catalog/promotions_test.rb`

- [ ] **RED:** test exclusive fixed/percentage fields, percentage range, monetary thresholds/caps, same-event product scope, event-namespaced digest, no plaintext logs, immutable version fields after first downstream reservation, manager vs staff authorization, one-promotion quote output, currency conversion, and stable evidence passed to checkout.

```ruby
# test/services/catalog/promotions/quote_test.rb
require "test_helper"

class Catalog::Promotions::QuoteTest < ActiveSupport::TestCase
  test "quotes one percentage discount with immutable evidence" do
    result = Catalog::Promotions::Quote.call(
      promotion: catalog_promotions(:launch_discount),
      code: "OPENING10",
      user: core_users(:buyer),
      eligible_subtotal_minor: 10_000,
      charge_currency: "ETB",
      fx_quote: nil
    )

    assert result.success?, result.error.inspect
    assert_equal 1_000, result.value.discount_minor
    assert_equal catalog_promotions(:launch_discount).id, result.value.promotion_id
  end
end
```

- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/quote_test.rb test/integration/catalog/promotions_test.rb`; expect missing promotion workflow.
- [ ] **GREEN:** implement immutable promotion definitions, event-namespaced codes, product scopes, and a read-only quote returning promotion/code/version/calculation/FX evidence. Material change creates a new promotion version linked by `supersedes_promotion_id`. The orders/payments plan exclusively owns `orders_promotion_redemptions` plus reserve/commit/release locks because that table requires `orders_orders`; this plan defines and contract-tests the quote it consumes rather than duplicating an order aggregate.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/promotions/quote_test.rb test/integration/catalog/promotions_test.rb`; expect pass.
- [ ] **Refactor:** explicitly reject arrays/multiple promotions. Keep organizer buyer discount separate from platform commission, processing fee, tax, and resale fee.
- [ ] **Commit:** stage listed files and commit `feat(catalog): add minimal buyer promotions`.

## Task 6: Add API, authorization, serializers, recurring work, and phase acceptance gate

**Files:**
- Create: controllers, policies, and serializers listed in the file map
- Modify: `config/routes.rb`
- Modify: `config/recurring.yml`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Create: `config/initializers/catalog_outbox_handlers.rb`
- Test: `test/integration/catalog/catalog_authorization_matrix_test.rb`
- Test: `test/integration/catalog/public_products_test.rb`
- Test: `test/integration/catalog/catalog_phase_acceptance_test.rb`

- [ ] **RED:** write an end-to-end test for a three-day group-of-three hybrid ticket with ETB base/USD override, inventory in packages, venue capacity in people, venue+stream accesses, explicit zone grants, 50/25/25 date allocations, one promotion quote, and invitation/access-code audience. Assert owner/manager/staff/scanner/public response differences and hidden-product behavior.
- [ ] **Run RED:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/catalog/catalog_authorization_matrix_test.rb test/integration/catalog/public_products_test.rb test/integration/catalog/catalog_phase_acceptance_test.rb`; expect uncovered route/policy/serializer failures.
- [ ] **GREEN:** complete nested organizer routes, quote/audience endpoints, Pundit scopes, serializer profiles, log filtering, recurring jobs, and Plan 0 outbox handlers for invitation delivery and catalog notifications. The domain initializer merges its handlers without replacing other domains' entries. `Core::Common` handles only plain draft CRUD; activation, quoting, reservation, code consumption, invitation claim, and promotion lifecycle remain command actions.
- [ ] **Run GREEN:** `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/catalog test/models/ticketing test/services/catalog test/services/ticketing test/integration/catalog test/integration/ticketing test/jobs/catalog test/jobs/ticketing`; expect pass.
- [ ] **Refactor:** run full suite, inspect SQL/query counts, and ensure public AMS output never contains counters, contacts, digests, FX-provider internals, promotion-code material, or restricted ticket policy.
- [ ] **Commit:** `git add app/models/catalog app/models/ticketing app/models/events/consent_document_product.rb app/controllers/catalog app/controllers/ticketing app/services/catalog app/services/ticketing app/services/events/consent_documents/replace_scope.rb app/jobs/catalog app/jobs/ticketing app/policies/catalog app/policies/ticketing app/serializers/catalog app/serializers/ticketing db/migrate/2026071702*.rb config test && git commit -m "test(catalog): complete composable catalog phase gate"`

## Phase acceptance gate

- Ticket, parking, merchandise, food, donation, digital add-on, and other products share one catalog without an event-type discriminator.
- A ticket product is one sellable package with immutable `admissions_per_unit`; quantity and price count packages while venue capacity counts people.
- ETB base, fixed currency override, and converted price quotes are deterministic and snapshot-ready; no historical consumer needs live FX.
- Concurrent reservations cannot oversell product inventory or event-date capacity and every lifecycle operation is idempotent.
- Stable product access IDs support venue, stream, parking, multi-day, hybrid, zones, and later QR payloads without mutable entitlement rows.
- Date allocations sum to 10,000 at commit and remain distinct from access rights.
- Exactly one buyer promotion may be quoted and codes never authorize admission; the orders/payments phase proves concurrent reservation/code/user limits against `orders_promotion_redemptions`.
- Public, organizer, manager, staff, scanner, and platform-admin tests prove policy and serializer boundaries.
- The full Rails test suite passes before registration work begins.
