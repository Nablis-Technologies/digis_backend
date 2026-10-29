# Organizer Payout Destination Design

## Goal

Allow an organization to configure a verified Chapa transfer destination for
post-event organizer payouts without storing beneficiary data in plaintext or
confusing direct transfers with Chapa split-payment subaccounts.

## Scope

This design adds organization-owned payout destinations, safe lifecycle
commands, payout-level destination snapshots, and the API/configuration needed
to dispatch Chapa Transfers in test mode. It does not implement Chapa
subaccount split settlement. Split payments remain a separate future product
because they settle during payment initialization rather than honoring the
post-event maturity hold.

## Provider contract

Chapa's direct transfer contract requires `account_number`, `bank_code`, and
`amount`; `currency`, `reference`, and `account_name` are also supported.
Digis sends these fields only from the verified destination selected for the
immutable payout snapshot. The existing
`Finance::PayoutProviders::ChapaTransferClient` remains responsible for HTTP,
response normalization, and timeout/unknown handling.

The application uses provider-first verification. When a payout adapter
supports beneficiary verification, the registration flow calls it and marks
the destination verified only after a successful provider result. When the
provider does not expose that capability, the destination remains pending;
a real transfer is never used as a verification probe. An explicit audited
Finance/platform-admin fallback may verify a pending destination only after
checking the account through the provider dashboard or approved financial
process.

Provider bank-list responses are normalized to numeric bank identifiers at the
Chapa transport boundary. An unavailable bank list is treated as unknown and
does not replace provider verification; a successfully retrieved list rejects
an identifier that is not present.

## Data model

### `finance_payout_accounts`

One organization may have multiple destinations, but the database permits only
one default destination per organization.

| Column | Rules |
|---|---|
| `organization_id` | Required FK to the owning organization |
| `type` | `bank` or `mobile_money` |
| `provider` | `chapa` at launch |
| `bank_code` | Required positive provider bank identifier |
| `account_number_ciphertext` | Active Record Encryption; never serialized or logged |
| `account_number_digest` | Keyed HMAC digest for deduplication without plaintext lookup |
| `account_name_ciphertext` | Active Record Encryption; verified holder name |
| `account_label_ciphertext` | Optional Active Record Encryption display label |
| `status` | `pending_verification`, `verified`, `suspended`, or `closed` |
| `verification_source` | `provider`, `test_fixture`, or `manual` when verified |
| `verified_by_id` | Optional Finance actor FK; absent for provider/test verification |
| `is_default` | Only a verified destination may be default |
| `verified_at` | Required exactly when status is `verified` |
| `last_used_at` | Updated after a provider submission, never used for authorization |
| timestamps | Required |

Constraints and indexes:

- UUIDv7 primary key.
- Unique (`organization_id`, `provider`, `account_number_digest`).
- Partial unique (`organization_id`) WHERE `is_default`.
- Foreign key to `organizations_organizations` with restrict-on-delete.
- Checks for type, provider, status, positive bank code, and verification
  metadata.
- Index (`organization_id`, `status`, `created_at`).

### `finance_payouts`

Add required `payout_account_id` to the original payout migration and associate
each payout with its selected destination. The payout serializer exposes only
the destination ID and safe status/label fields. Historical payout meaning
cannot change when an organization replaces its default destination.

## Lifecycle

### Register

`Finance::PayoutAccounts::Register`:

- requires an idempotency key;
- binds the idempotency key to the normalized request and actor so reusing a key
  for different beneficiary data returns a conflict;
- normalizes type/provider/bank code/account number/account name;
- derives the keyed account-number digest;
- encrypts beneficiary fields before persistence;
- runs provider-first verification after persistence when the adapter supports
  it;
- leaves the destination pending when provider verification is unsupported or
  returns an unknown/timeout result;
- never marks the destination verified from local syntax checks alone.

### Verification sources

Provider verification is the preferred source. Test fixtures may use the
explicit `test_fixture` source. A manual Finance fallback requires a reason and
evidence reference, records `manual` as the source, and is unavailable to organizers.

### Select default

`Finance::PayoutAccounts::SetDefault`:

- is restricted to an organization owner/admin or platform administrator;
- locks the organization and destination rows in deterministic order;
- requires the destination to be verified and not closed/suspended;
- clears the previous default and sets the new default atomically;
- is idempotent by client key.

Every lifecycle command records a keyed request digest in its audit metadata.
An exact replay returns the original destination; a different destination,
actor, reason, evidence reference, or registration payload using the same key
returns `idempotency_conflict`.

### Suspend and close

Suspension is a Finance/platform-admin action that immediately prevents new
payout dispatches. Closing is terminal and is allowed only after the
destination is no longer the organization's default. Existing payout rows
retain their snapshot and remain reconcilable.

## Payout flow

1. `Finance::BuildPayout` locks the organization/currency scope and requires a
   verified default destination.
2. It stores `payout_account_id` on the payout row with the reserved
   allocations.
3. `Finance::DispatchPayout` locks the payout, allocations, and destination,
   rechecks that the destination is still verified, and passes decrypted
   beneficiary data only to the injected payout adapter.
4. The adapter submits one idempotent Chapa transfer using the payout
   idempotency reference.
5. A success consumes allocations and appends the payout ledger row. Failure
   releases them. Timeout/unknown remains processing and is reconciled through
   Chapa's transfer verification endpoint without resubmission.

## API surface

All routes are organization-scoped:

- `GET /finance/organizations/:organization_id/payout_accounts`
- `POST /finance/organizations/:organization_id/payout_accounts`
- `POST /finance/organizations/:organization_id/payout_accounts/:id/verify`
- `POST /finance/organizations/:organization_id/payout_accounts/:id/set_default`
- `POST /finance/organizations/:organization_id/payout_accounts/:id/suspend`
- `POST /finance/organizations/:organization_id/payout_accounts/:id/close`

The serializer never exposes account number, encrypted columns, keyed
digests, or provider secrets. Mutating routes require `Idempotency-Key`.
User-facing errors use locale entries, and every route is mirrored in the
Postman collection with non-sensitive example values.

## Seeds and environments

- Production-safe base seeds create no organizer payout destination.
- Preview/dev seeds create one synthetic verified Chapa destination for the
  seeded organizer using non-production test values.
- `CHAPA_PAYOUT_ENABLED` remains an explicit environment toggle.
- Render preview stays in `CHAPA_MODE=test`; no live key or real beneficiary
  data is added to source control.

## Migration strategy

Create `finance_payout_accounts` in its own migration ordered before the
original `create_finance_payouts` migration, then edit the original payout
migration to add the foreign key and column. Because this repository is
pre-production and the project rules prohibit compatibility migrations for
existing tables, local and preview databases must be reset after applying the
edited original migration.

## Security and audit invariants

- Active Record Encryption protects beneficiary fields at rest.
- Keyed digests support deduplication without reversible lookup.
- Plaintext account data is never placed in logs, audit metadata, serializers,
  Postman, seeds, or error messages.
- Verification, default selection, suspension, closure, and payout use are
  audited with actor and idempotency evidence.
- Organization authorization and Finance verification are separate checks.
- No payout may dispatch without a verified destination snapshot.

## Verification requirements

Tests must cover model/database constraints, registration idempotency,
same-key/different-request conflicts,
verification authorization and replay, default-selection concurrency,
serializer privacy, payout snapshotting, dispatch refusal for unverified or
closed destinations, Chapa request mapping, timeout reconciliation, Render
configuration, seeds, routes, Postman coverage, `N_PLUS_ONE=1`, RuboCop, and
Zeitwerk.
Tests must also prove provider-first verification, unsupported-provider
fallback to pending, test-fixture verification, and manual fallback audit
metadata without exposing beneficiary data.
