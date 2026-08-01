# Catalog Promotions Design

**Date:** 2026-08-01

**Status:** Approved for implementation

## Goal

Implement the catalog buyer-promotion contract for one non-stackable promotion
quote. Organizers can create immutable promotion versions, attach event-scoped
codes and optional product scope, publish or disable versions, and request a
deterministic discount quote whose evidence can be passed to checkout.

## Scope

This feature owns:

- `catalog_promotions`
- `catalog_promotion_codes`
- `catalog_promotion_products`
- Promotion definition, code, lifecycle, reveal, and quote commands
- Organizer-scoped promotion APIs and serializers
- Promotion locales, development seed data, and Postman examples

The Orders phase owns `orders_promotion_redemptions` and all concurrency,
global-limit, code-limit, and per-user-limit enforcement. Task 5 returns those
limits as immutable quote evidence but does not count redemptions before the
Orders aggregate exists.

## Decisions

### Version immutability

Promotion calculation fields, currency, limits, windows, and product scope are
editable only while a promotion is `draft`. A published or disabled promotion
is immutable. A material change creates a new draft version linked through
`supersedes_promotion_id`; publishing the new version disables the superseded
active version in the same transaction.

Draft edits use `Catalog::Promotions::Update` through `PATCH
/catalog/promotions/:id`. The command locks the draft, replaces its product
scope atomically, validates the full candidate definition, and records an
idempotent audit. `DELETE /catalog/promotions/:id` uses
`Catalog::Promotions::DeleteDraft` and is allowed only for drafts. Published
and disabled versions cannot be deleted.

This is intentionally stricter than waiting for the future Orders reservation
table. It prevents a published policy from changing underneath checkout and
avoids a cross-domain dependency on a table that does not exist yet.

### Promotion codes

The API accepts a plaintext code when creating a code. The model stores:

- An event-namespaced keyed digest for lookup and uniqueness
- Rails-encrypted ciphertext for organizer retrieval

The plaintext is returned in the creation response and is never included in a
normal serializer, audit payload, or log. Organizers can explicitly retrieve
it later through a manager/admin-authorized `POST` reveal action. Each reveal
is audited without recording the plaintext.

Codes are normalized by trimming and uppercasing before digesting and lookup.
The same canonical value is assigned to the encrypted `code_ciphertext` column
and passed to `Core::KeyedDigest.digest`; `Core::KeyedDigest.normalize` is not
changed because existing access-code and invitation digests depend on its
strip-only behavior. The visible code is therefore case-insensitive while the
event namespace keeps identical codes from different events independent.

### Quote inputs and scope

The quote command accepts:

- `promotion`
- plaintext `code`
- `eligible_product_ids`
- `eligible_subtotal_minor`
- `charge_currency`
- optional `fx_quote` evidence
- optional `at` timestamp

The command verifies that every eligible product belongs to the promotion's
event. If the promotion has product-scope rows, every supplied product must be
within that scope. The caller supplies the already-computed eligible subtotal;
the Orders phase remains responsible for deriving that subtotal from current
order items.

An unscoped promotion applies to any product in its event. A scoped promotion
requires at least one eligible product ID. Task 5 does not calculate order line
prices or accept arbitrary line-item prices from the client.

### Redemption limits

Task 5 validates that limits are positive and includes them in promotion and
quote evidence. It does not enforce usage counts. The Orders phase will lock
the promotion and code and count unexpired `reserved` plus `applied` rows when
creating `orders_promotion_redemptions`.

### Currency conversion

Promotion monetary fields are denominated in the promotion currency. The quote
converts thresholds, fixed discounts, and caps into the charge currency using
the same exchange-rate evidence used by product pricing. The conversion path
uses one shared pricing converter rather than duplicating rounding logic in the
promotion service.

If the currencies match, no FX evidence is required. If they differ, the
promotion converter uses supplied `fx_quote` evidence when present and
validates its exchange-rate ID/value against the stored rate. Without usable
evidence it resolves the applicable rate at the quote timestamp and returns
that rate as immutable evidence. This optional evidence-validation path is a
new promotion capability; the existing product quote path remains DB-rate-only
and keeps its current public behavior. Both paths use the same conversion and
rounding implementation. Currency-specific minor units and half-up rounding
match the existing catalog pricing behavior.

Discount calculation is:

- Percentage: eligible subtotal multiplied by basis points, divided by 10,000,
  rounded half-up, then limited by the converted maximum cap and subtotal.
- Fixed: converted fixed amount, limited by the converted maximum cap when
  present and never greater than the eligible subtotal.

The minimum subtotal is checked after conversion into the charge currency. A
subtotal below the threshold returns a localized business failure rather than
a zero-value success.

## Data Model

The repository rule of one table per migration overrides the older plan's
combined migration name. The implementation creates three migrations.

### `catalog_promotions`

Columns:

- `event_id` UUID, required foreign key
- `supersedes_promotion_id` UUID, optional self foreign key
- `version` integer, required, starts at 1
- `name` string, required
- `type` string, `percentage` or `fixed`; STI disabled
- `percentage_basis_points` integer, nullable except for percentage type
- `fixed_amount_minor` bigint, nullable except for fixed type
- `currency` string, required ISO-4217 alpha-3
- `minimum_subtotal_minor` bigint, nullable nonnegative
- `maximum_discount_minor` bigint, nullable positive
- `redemption_limit` integer, nullable positive
- `per_user_limit` integer, required positive defaulting to 1
- `starts_at` timestamptz, optional
- `ends_at` timestamptz, optional and after `starts_at`
- `status` string, `draft`, `active`, or `disabled`
- `lock_version` integer, required defaulting to 0
- timestamps

Database checks enforce type/status allowlists, exactly one calculation value,
percentage bounds, nonnegative money, positive limits, and valid windows.

### `catalog_promotion_codes`

Columns:

- `promotion_id` UUID, required foreign key
- `code_digest` string, required and globally unique
- `code_ciphertext` text, required Rails-encrypted storage
- `label` string, optional
- `redemption_limit` integer, nullable positive
- `starts_at` timestamptz, optional
- `ends_at` timestamptz, optional and after `starts_at`
- `active` boolean, required defaulting to true
- timestamps

The model exposes a transient/plaintext `code` accessor backed by the
`code_ciphertext` column. Serializers never expose either the digest or
ciphertext.

### `catalog_promotion_products`

Columns:

- `promotion_id` UUID, required foreign key
- `event_product_id` UUID, required foreign key
- timestamps

The `(promotion_id, event_product_id)` pair is unique. Service validation
ensures both rows belong to the same event as the promotion; product IDs in a
quote are checked against this scope.

## Services

All commands inherit from `Core::BaseService`, normalize hashes at the service
boundary, use locale-backed failures, and run their authoritative writes in a
transaction.

- `Catalog::Promotions::Create`: creates a draft version, validates the event
  and optional product scope, sets the next version number, validates
  `version == superseded.version + 1` and same-event lineage, and records an
  audit entry.
- `Catalog::Promotions::Update`: updates a draft definition and replaces its
  product scope atomically. Published and disabled versions are rejected.
- `Catalog::Promotions::DeleteDraft`: deletes only an unused draft and records
  an idempotent audit; active and disabled versions are rejected.
- `Catalog::Promotions::CreateCode`: normalizes the plaintext code, stores its
  digest and encrypted value, validates promotion/event ownership, and returns
  a result object containing the record plus plaintext only for the creation
  response.
- `Catalog::Promotions::RevealCode`: authorizes the caller, decrypts the code,
  records an audit event without the plaintext, and returns the transient code.
- `Catalog::Promotions::PublishVersion`: locks a draft, validates its active
  window and definition, disables a superseded active version, and activates
  the new version atomically. Replays of an already-active version are
  idempotent.
- `Catalog::Promotions::Disable`: locks the promotion and transitions active
  to disabled. Replays of a disabled version are idempotent; a draft cannot be
  disabled through the publish lifecycle.
- `Catalog::Promotions::Quote`: validates the active promotion, code, time
  windows, product scope, minimum subtotal, and charge currency; calculates one
  discount; and returns immutable `Catalog::PromotionQuote` evidence. It does
  not count redemptions.
- `Catalog::Pricing::CurrencyConverter`: shared conversion/evidence component
  extracted from the existing product quote calculation. It preserves the
  current DB-rate-only product path and adds an explicit, validated evidence
  input for promotions. Existing product pricing continues to produce
  `Catalog::PriceQuote`, while promotion pricing produces its own
  promotion-specific evidence object.

Mutating HTTP actions require `Idempotency-Key` through the shared resolver.
Reveal uses the same guard because it creates an audit transition. Each command
canonicalizes its input and derives a request digest. A deterministic command
audit key, guarded by `Core::Database::AdvisoryLock`, is the replay boundary;
`Core::Audit::Record` stores only the digest and created record ID in metadata.
An identical replay returns the original/current record without a duplicate
side effect. A reused key with a different request digest returns a localized
conflict. Raw promotion codes never appear in audit metadata.

## Immutable Quote Evidence

`Catalog::PromotionQuote` is a frozen `Data.define` value containing:

- `promotion_id`
- `promotion_code_id`
- `promotion_version`
- `eligible_product_ids`
- `eligible_subtotal_minor`
- `discount_minor`
- `charge_currency`
- `promotion_currency`
- `calculation_type`
- `percentage_basis_points`
- `fixed_amount_minor`
- `minimum_subtotal_minor`
- `maximum_discount_minor`
- `redemption_limit`
- `per_user_limit`
- `code_redemption_limit`
- `code_starts_at`
- `code_ends_at`
- `code_active`
- `exchange_rate_id`
- `exchange_rate_value`
- `at`

The serializer exposes calculation and FX evidence needed by checkout but never
exposes plaintext codes, encrypted values, or code digests.

## HTTP API

The API uses the existing `/catalog` scope and organizer authorization model.

- `GET /catalog/promotions`: list promotions in manageable events
- `GET /catalog/promotions/:id`: show a promotion and safe code metadata
- `POST /catalog/promotions`: create a draft, optionally with `product_ids`
- `PATCH /catalog/promotions/:id`: update a draft, optionally replacing
  `product_ids`
- `DELETE /catalog/promotions/:id`: discard a draft only
- `POST /catalog/promotions/:id/publish`: publish a draft version
- `POST /catalog/promotions/:id/disable`: disable an active version
- `POST /catalog/promotions/:id/quote`: quote one promotion using `code`,
  `eligible_product_ids`, `eligible_subtotal_minor`, `charge_currency`, and
  optional `fx_quote`
- `GET /catalog/promotion_codes`: list safe code metadata
- `GET /catalog/promotion_codes/:id`: show safe code metadata
- `POST /catalog/promotion_codes`: create a code and return plaintext once
- `POST /catalog/promotion_codes/:id/reveal`: return plaintext after explicit
  manager/admin authorization and audit logging

Promotion-code reads expose ID, promotion ID, label, limits, windows, active
state, and timestamps only. Promotion responses expose safe definition fields,
product scope IDs, and lifecycle metadata. Policy visibility remains explicit
for every action.

## Errors and Locales

No promotion error string is hard-coded in a model, service, or controller.
Locale files under `config/locales/catalog/` provide messages for:

- invalid promotion type/status
- exclusive calculation fields
- invalid percentage or monetary values
- invalid limits and time windows
- event/product scope mismatch
- immutable published/disabled version
- invalid or unavailable code
- code window/status failure
- minimum subtotal failure
- unsupported conversion or invalid FX evidence
- unauthorized reveal
- draft-only update/delete lifecycle failures
- idempotency conflict

Controllers pass translation keys or `Core::Error` results through the existing
JSON response helpers.

## Seed and Postman

`db/seeds/dev.rb` creates an idempotent active promotion for the existing fest
event, attaches a scoped VIP product where appropriate, creates a sample code,
and prints only a local-development instruction for the raw code without
logging it through application request logs. The seed uses the promotion
commands so it exercises real behavior.

`postman/Digis API_collection.json` adds promotion list/show/create, publish,
update, draft deletion, disable, quote, code creation, safe code reads, and
reveal examples. Requests include required idempotency headers for mutating
endpoints and example payloads match the serializers and locale-backed error
contracts. The member quote route is deliberate: unlike the existing flat
product quote endpoint, promotion eligibility is authorized against the
promotion aggregate and its event/product scope.

## Testing

TDD coverage includes:

- Model/database checks for type, status, exclusive fields, bounds, windows,
  limits, encrypted code storage, global digest uniqueness, and scope uniqueness
- Service tests for draft creation, version linking, publication/disable
  lifecycle, same-event scope, code normalization, reveal auditing, and
  idempotency
- Quote tests for fixed and percentage calculations, minimum/cap behavior,
  half-up rounding, currency conversion, FX evidence, invalid codes/windows,
  scoped product validation, and immutable quote evidence
- Integration tests for organizer/manager/staff/scanner/public authorization,
  request normalization, required idempotency headers, Postman-facing payloads,
  and plaintext-code privacy
- `N_PLUS_ONE=1` runs for all promotion tests and the full suite
- `bundle exec rubocop`, `git diff --check`, and Rails loader/schema checks

Known unrelated cleanup: the full N+1 suite currently reports five activation
errors in `Catalog::Products::Activate#zones_active_for?`; Task 5 verification
will report that separately unless it is fixed as an explicitly agreed scope
change.

## Non-goals

- Promotion stacking or priority/exclusion rules
- Orders redemption reservations or usage counters
- Payment, tax, commission, or platform-fee discounts
- Client-provided arbitrary FX rates without database evidence
- Plaintext code exposure in normal serializers or logs
