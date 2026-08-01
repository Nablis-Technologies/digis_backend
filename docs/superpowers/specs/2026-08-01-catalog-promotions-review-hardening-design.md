# Catalog Promotions Review Hardening

## Goal

Address the five actionable findings from the Task 5 review without changing
the approved promotions behavior. The changes cover authorization lookup
boundaries, malformed product-scope input, activation query efficiency, and
foreign-exchange failure propagation.

The harmless `DeleteDraft#replay_or_not_found` transaction placement and the
required `PromotionQuoteSerializer#read_attribute_for_serialization` override
remain unchanged.

## Design

### Scoped resource lookup

Use the existing Pundit scopes as the lookup boundary:

- Promotion show/update/publish/disable/quote lookups resolve through
  `policy_scope(Catalog::Promotion)`.
- Promotion-code show/reveal lookups resolve through
  `policy_scope(Catalog::PromotionCode)`.
- Promotion-code creation resolves its parent promotion through the scoped
  promotion relation.
- Draft deletion uses the scoped lookup when the record exists and retains the
  promotion ID-only replay path for a previously deleted record.

An inaccessible existing record therefore behaves like an inaccessible
resource rather than exposing existence through an authorization response.

### Product-scope input

`product_ids` is a list-valued API field and will be validated at the service
boundary, not trusted because of controller parameter filtering.

- `nil` means no scope on create.
- `nil` means preserve the existing scope on update.
- An empty array explicitly clears an update scope.
- Any non-array, non-nil value returns a localized validation failure.

The service layer remains safe for non-HTTP callers, while the existing
controller behavior and request digest semantics remain intact.

### Activation zone lookup

`Catalog::Products::Activate#validate_zone_mappings!` will preload product
access associations as it does today, then issue one active-zone query for the
relevant event and access types. In-memory membership checks will preserve the
current rules:

- Dated access matches a zone scoped to that date or an undated zone.
- Undated access matches any active zone of the same type.
- An active zone is still required before an empty access-to-zone mapping is
  rejected.

The per-access `zones_active_for?` query will be removed or converted to a
pure lookup against the preloaded set.

### FX conversion failures

`Catalog::Promotions::Quote` will treat every conversion as a `Core::Result`:

- Minimum subtotal conversion failures are returned immediately.
- Fixed discount conversion failures are returned immediately.
- Maximum discount conversion failures are returned immediately.
- Existing localized converter errors are preserved.

Unsupported currency pairs continue to fail at the initial conversion. The
additional propagation protects against later evidence/rate lookup failures
and prevents silently skipping a minimum/cap or performing nil arithmetic.

## Tests

Add or update tests for:

- Inaccessible promotion and promotion-code IDs not being loaded outside the
  manageable policy scope.
- Scalar `product_ids` being rejected and array semantics remaining unchanged.
- Omitted update `product_ids` preserving scope and `[]` clearing it.
- Activation lifecycle tests passing with `N_PLUS_ONE=1`.
- FX conversion failures from minimum, fixed, and maximum calculations being
  returned as failures.

Run focused tests first, then the normal suite, N+1 suite, targeted RuboCop,
full RuboCop, Zeitwerk, Brakeman, and `git diff --check`. Existing unrelated
full-suite failures will be reported separately if they remain.

## Non-Goals

- Do not change the promotion quote schema or serializer fields.
- Do not remove the Data serializer override.
- Do not change deletion replay transaction behavior.
- Do not introduce a generalized lookup abstraction for unrelated modules.
