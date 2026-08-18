# Native Scanner Contract v1

This document and the JSON fixtures under
`test/fixtures/files/ticketing/` are the cross-language authority for scanner
validation. Native clients must consume the fixtures and this decision table;
they must not recreate a second business validator from a server endpoint or
from a UI-specific rule set.

## Contract inputs

The signed credential claims are exactly:

`kid`, `cid`, `tid`, `eid`, `mode`, `slots`, `entry_limit`, `v`, `accesses`,
and `exp`.

The scanner stores public signing keys only. A private signing seed never
enters a scanner snapshot, local database, upload, or response. The envelope
is decoded, its signature is verified over the canonical claims JSON, and only
then are claims parsed and validated.

Envelope failures have stable codes:

| Condition | Code |
| --- | --- |
| malformed envelope or missing signature | `invalid_qr_token` |
| signature cannot be verified | `invalid_qr_signature` |
| signing key is not in the synchronized key set | `unknown_qr_key` |
| claims expiry is at or before scanner time | `expired_qr_token` |
| claims contain the wrong fields or shape | `invalid_credential_claims` |

After envelope verification, QR, PNR/code, phone, name, and online selection
must reconstruct the same `Ticketing::CredentialClaims` shape and use the
same decision order:

1. claims shape;
2. expiration;
3. event;
4. product access;
5. event-date window;
6. access zone and scanner assignment zone;
7. terminal package state;
8. generation revocation;
9. exact credential revocation;
10. active-use ceiling.

The stable validator outcomes are listed in
`credential_contract_v1.json`. `valid` is the only outcome that may proceed
to admission-use allocation. A group credential is all-or-nothing: every
required slot must pass the same checks before any local use is written.

## State mirrored locally

A native scanner database contains the following logical tables:

- `revocations`: ticket/package generation cutoffs and terminal or suspended
  state;
- `credential_revocations`: exact credential/CID revocations;
- `scans`: immutable local attempts keyed by globally unique
  `client_scan_id`;
- `local_admission_uses`: local/server use IDs, slot position, access, and
  monotonic usage number;
- `admission_use_reversals`: server reversal ID/group/version rows;
- `access_zones`, `product_access_zones`, and `scanner_assignment_zones`;
- `attendee_lookup`: PNR/phone-hash lookup projections with tombstones and
  index version;
- `scanner_state`: event, feed cursors, signing-key set, and last sync time.

The local schema must keep the server use ID separate from the client scan ID.
An unsynced local use cannot be reversed locally. Reversal rows reduce the
active-use count but never reuse a historical `usage_number`.

## Atomic synchronization apply

One full snapshot or delta is applied inside one SQLite transaction in this
order:

1. server admission-use IDs;
2. package/generation revocations;
3. exact credential/CID revocations;
4. attendee-index tombstones;
5. attendee-index additions and updates;
6. admission-use reversals;
7. schedule, access-zone, product-zone, and assignment-zone policies;
8. feed cursors and scanner state.

The cursor write is last. If the process crashes before the cursor commit, the
same response can be applied again safely because rows are keyed by their
server IDs and tombstones are idempotent. A client must never advance one
cursor independently of the other feed families.

The server response is an allowlisted projection. It must not contain answers,
consent evidence, identity documents, finance, resale, payout, or operator
notes. `ScannerSyncSerializer` and `scanner_sync_contract_v1.json` enforce the
same boundary on the Rails side.

## Offline replay and conflicts

- Repeating a completed `client_upload_id` returns the exact stored response.
- Repeating a `client_scan_id` in another upload returns the original server
  result and does not create another check-in or use.
- A disconnected scanner may record `success` for a credential that another
  disconnected scanner also accepted. Server reconciliation is authoritative;
  deterministic locks and the first server admission use make the winner
  `success` and the later result `duplicate`.
- A scanner missing a reversal delta may conservatively continue returning
  `already_used`; it must not invent a new allowance.

These semantics cover crash-before-cursor-commit replay and the unavoidable
disconnected freshness window. They do not claim that a disconnected client
can know a revocation that it has not synchronized.

## Scale gates

The Rails-side performance test serializes the production-shaped contract at
the following explicit sizes:

- 50,000 attendee-index entries for a full snapshot;
- 500 scan results for one upload response.

The budgets are recorded in `scanner_sync_contract_v1.json` and enforced by
`test/performance/ticketing/scanner_sync_performance_test.rb`. This repository
does not contain a native client or a bundled `sqlite3` runtime, so those tests
measure the shared payload contract and Rails serialization only. The native
client build must additionally run the same fixtures against its real SQLite
transaction and report that result before the final cross-platform acceptance
gate.

## Contract changes

Any incompatible claims, decision, feed, or local-apply change requires a new
contract version and fixtures. Additive allowlisted fields are not implicitly
safe: update the serializer, privacy assertions, documentation, and every
native client together.
