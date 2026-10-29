# Phone-Based Event Scanner Invitations and Pairing

**Status:** Approved for implementation; no implementation has started.

**Source:** Organizer/scanner onboarding proposal shared on 2026-10-07.

## Goal

Let an authorized event organizer invite gate staff using a phone number instead of asking them for an internal UUID. The invitee can pair a phone with the event scanner in a passwordless flow. Once paired, the device can access only the assigned event's scanner capabilities, continue scanning offline within the existing scanner contract, and be revoked by the organizer.

This is an event-scoped staff/device enrollment feature. It is not a replacement for the existing ticket-transfer flow, event staff roles, credential validation, or offline scan reconciliation.

## Current-state evidence

- `POST /events/:event_id/event_staff_assignments` currently accepts `user_id` and a role. `Events::StaffAssignments::Assign` creates an immediately active event assignment. The organizer-facing flow therefore requires a UUID and has no pending invitation lifecycle.
- `Events::EventStaffAssignment` supports event-scoped roles including `scanner`, with active/suspended/revoked/expired states. It has no `invited` state; an invitation should not be modeled as an active staff assignment.
- `Ticketing::ScannerDevice`, `Ticketing::ScannerDeviceAssignment`, `Ticketing::Scanners::RegisterDevice`, and `Ticketing::Scanners::AssignToEvent` provide useful primitives. The register/assign services are not currently exposed through first-class enrollment endpoints.
- Current scanner authentication requires both a normal authenticated user and a device token, then checks the user's event role and the device's event assignment. The device assignment is not explicitly bound to the invited operator.
- Scanner sync and upload already support full/delta synchronization, offline attempts, and idempotent reconciliation. They cannot make a disconnected device learn about a revocation it has not synchronized.
- An empty scanner-zone assignment is not equivalent to “all zones”: the existing admission authorization path requires explicit zone grants when zones are configured.
- Existing security guidance treats scanner device tokens as secrets, requires token rotation/revocation auditing, and documents the unavoidable offline freshness window. The enrollment design must preserve those properties.

## Proposed product and security decisions

1. **Phone is the organizer's input; UUID remains an internal identifier.** Normalize the phone to E.164 using the existing phone-identity rules. Do not ask organizers to find or paste a `Core::User` UUID.
2. **Invitations are separate from active assignments.** Create an invitation first. Create/activate `Events::EventStaffAssignment` and the event-scoped scanner-device assignment only after successful claim and pairing.
3. **Pairing is a delegated, event-scoped capability—not proof of a person's legal identity or verified phone ownership.** A high-entropy link delivered by SMS and a QR displayed by an authenticated organizer can be redeemed without a second OTP. The person who can redeem the capability is the operator the organizer authorized for this scanner assignment. Do not set `phone_verified_at` or otherwise claim that the invitation verified phone ownership. If stronger identity assurance becomes a requirement, add an explicit verification policy rather than silently inserting a second OTP into every path.
4. **No global organizer promotion.** Pairing grants only the event-scoped `scanner` role. It must not add `ORGANIZER` or other global platform permissions.
5. **Use one scanner-scoped bearer session, not a general-purpose access token in the scanner PWA.** `POST /scanner/pair` returns one opaque `scanner_session_token`; subsequent scanner API requests use `Authorization: Bearer <scanner_session_token>`. The session is bound to one event, one event staff assignment, and one device. It cannot access finance, organizer dashboards, attendee exports, or unrelated APIs.
6. **“Revoke now” means immediate server-side denial while online.** A disconnected device may continue using its last synchronized offline projection until it reconnects or its local session expires. The organizer UI and API must not promise an instant offline kill switch.
7. **“All zones” is explicit.** The initial default is `all_current_zones`, resolved to the current zone IDs when pairing is activated. Newly created zones are not silently granted; the organizer must update the assignment. Selected-zone mode persists only the selected IDs. An empty zone list never means all zones.
8. **Session end is bounded.** Default expiry is six hours after the latest scheduled event-date end. If the event has no finite schedule end, the organizer must provide a finite scanner access end time. The session cannot be permanent by omission.
9. **Invitation authority belongs to the event.** The creator must have permission when creating the invitation. After that, the valid, unrevoked, unexpired invitation remains a durable event-scoped grant even if its creator later loses their manager role. Pairing must not recheck the creator's current membership. An authorized event manager can explicitly revoke the invitation; event cancellation and expiry also invalidate it.

## Recommended flow

### Organizer

1. On the event's **Gate & Scanners** surface, enter a phone number and optional staff label/note. Choose `all_current_zones` or selected zones, and review the scanner access window.
2. Submit an idempotent create-invitation request. The backend validates that the actor can assign the `scanner` role for this event and that the phone, zones, and access window are valid.
3. The response shows the pending invitation, masked phone, selected scope, expiry, and one-time pairing material (short code and QR/magic-link form). Pairing secrets are returned only to an authorized organizer and are not included in logs, audit metadata, analytics, or ordinary serializers.
4. SMS delivery is asynchronous. The UI distinguishes `queued`, `accepted`, `delivered` when supported by the provider, `failed`, and `unknown`; it must not say “sent” merely because a job was enqueued. A resend rotates the invitation's active pairing material and invalidates the prior material. Delivery links use the separately configured scanner-app origin and carry the capability in a URL fragment, never a query/path.
5. The roster combines pending invitations and paired assignments. It shows invite/claim state, masked phone, label, zone scope, access window, delivery state, and server-reconciled scan count. Offline, not-yet-uploaded scans are not represented as server-confirmed scans.
6. Organizer actions are scoped and distinct: resend/rotate a pending invitation, reset pairing when a paired session is lost, revoke a pending invitation, revoke one event assignment, and revoke a whole device for loss/theft. Reset moves the invitation to `pairing_reset`, preserves the existing event staff assignment, revokes old device assignments/sessions, and issues fresh one-time pairing material. Re-pair uses the same operator assignment and never reveals the old plaintext session token.

### Scanner staff

1. Staff opens the SMS magic link, scans the organizer's authenticated on-screen QR, or enters the short on-site code in the scanner PWA. The link/QR are high-entropy, single-use capabilities. The manual code is lower entropy and is accepted only within its short expiry and attempt limits.
2. No secondary OTP is required for the magic-link or organizer-QR paths. The PWA sends the capability to `POST /scanner/pair` in the request body and removes it from browser history/referrer context. Pairing records the method (`sms_link`, `organizer_qr`, or `short_code`) for audit; it does not mark the invited phone as verified.
3. The backend atomically claims the invitation, resolves or provisions the minimal operator record required by the event-staff model without global roles or a verified-phone assertion, activates the event-scoped scanner assignment, registers/binds the device, and issues a scanner-scoped session. The operator identity is attributable to the organizer's invitation, not asserted to be the natural person who physically redeemed a forwarded capability.
4. The PWA displays the event, event dates, allowed zones, access expiry, and a clear **Start scanning** action. The scanner session is persisted by the client so reopening the PWA can resume it while the session remains valid.
5. Scanner APIs expose only the existing allowlisted sync and scan-upload data. Ticket credential validation and offline reconciliation continue to follow the native scanner contract.

## Domain model and ownership

### `Ticketing::ScannerInvitation` (new aggregate)

Owns the invitation lifecycle, normalized recipient phone, delivery/retry revision, one-time pairing capabilities, expiry, and the link to the claimed operator/device/assignments. Proposed states: `pending`, `paired`, `pairing_reset`, `expired`, `revoked`. Delivery state is separate from invitation state. A reset keeps the existing event staff assignment but revokes old device assignments/sessions and requires a fresh capability to bind the replacement/current device.

Sensitive data and capability handling:

- Store phone ciphertext plus a keyed HMAC digest for scoped lookup/deduplication; do not index plaintext phone numbers.
- Store the high-entropy token digest for lookup and the token encrypted at rest while the invitation is pairable; clear ciphertext on pairing, revoke, or expiry. The SMS job receives only the invitation ID and delivery revision and decrypts transiently at delivery time. Never put the raw token in a job argument, audit record, or log. A capability is single-use and invitation-expiry-bound.
- Store a keyed digest for short-code lookup and keep the code encrypted only until its 10-minute expiry so an authorized idempotent response can be replayed safely. Clear expired ciphertext, apply strict attempt limits, and rotate both code and link token on resend; older revisions become invalid.
- Keep note/label separate from the secret and bound its length. The staff note is organizer-only and must not enter attendee/scanner sync projections.

### Existing aggregates

- `Events::EventStaffAssignment` remains the authority for the human's event role. It is created as active only after successful capability redemption; scanner is an event-scoped role. The invitation phone remains unverified unless a separate phone-verification flow has actually verified it.
- The scanner invitation is the durable delegation authorizing that later assignment. Ticketing validates and consumes the locked invitation, then passes an event/role/grantor-scoped grant to an Events-owned assignment command. Events must not query or depend on Ticketing models; the grant retains the original inviter for attribution without rechecking their current permission.
- `Ticketing::ScannerDevice` remains the organization-scoped device identity. Its installation identifier is generated by the PWA and is not the staff phone number or a user-entered UUID. Device identity/lifecycle remains separate from authentication; remove the obsolete device bearer-token credential once the scoped session contract replaces it.
- `Ticketing::ScannerDeviceAssignment` remains the event/device/time/zone scope. Add an `event_staff_assignment_id` link in its original migration and derive the operator through that association; do not store a redundant `operator_id`. A different event staff assignment cannot borrow the paired device session.
- A new `Ticketing::ScannerSession` owns the keyed digest of the opaque bearer token, event/staff/device binding, expiry, and revocation. Return the plaintext token only from successful pairing; never persist or serialize it. A dedicated record is preferred over overloading the long-lived device token because one device can have separate event assignments and session lifecycles.
- Orders, attendee registration, ticket transfer, and ticket ownership are unchanged.

## API contract proposal

The contract should expose these operations:

| Operation | Proposed route | Purpose |
| --- | --- | --- |
| Create invite | `POST /events/:event_id/scanner_invitations` | Organizer creates a pending invite; requires `Idempotency-Key`. |
| List roster | `GET /events/:event_id/scanners` | Dedicated roster projection: pending invitations and paired scanner assignments as separate collections of safe projections. This is not an invitation-resource response containing unrelated assignment records. |
| Resend/rotate | `POST /scanner_invitations/:id/resend` | Rotates a pending invite's link/code and queues delivery; old revision stops working. Requires `Idempotency-Key`. |
| Reset pairing | `POST /scanner_invitations/:id/reset_pairing` | Organizer-authorized recovery after a paired PWA loses its session; revokes the old session and rotates pairing material without returning the old token. Requires `Idempotency-Key`. |
| Revoke invite | `POST /scanner_invitations/:id/revoke` | Invalidates unclaimed pairing material. Requires `Idempotency-Key`. |
| Redeem/pair | `POST /scanner/pair` | Accepts exactly one invitation capability (link/QR token or short code) and generated installation metadata; requires `Idempotency-Key`; atomically claims and returns a scoped scanner session. No normal user JWT or second OTP is required. |
| Update scanner scope | `PATCH /events/:event_id/scanner_device_assignments/:id` | Updates selected zones and finite access window for a paired event assignment, bumps the event schedule cursor, and requires `Idempotency-Key`. Online access changes take effect on the next request; offline clients apply the new zone projection on sync and may retain stale access until then or local session expiry. |
| Revoke event access | Existing `POST /events/:event_id/event_staff_assignments/:id/revoke` | Reuse the existing event-staff revoke URL. For scanner assignments, the command path must also invalidate the event/device assignment and scoped session without making the `Events` module depend on `Ticketing`. Requires `Idempotency-Key`. |
| Revoke device | Existing `POST /scanner_devices/:id/revoke` | Retains device-wide lost/stolen-device semantics and revokes its assignments/sessions. |
| Rotate device credential | Existing `POST /scanner_devices/:id/rotate_token` | Retire this route and its device-token implementation; scanner authorization uses scoped sessions, and lost-token recovery uses organizer-authorized pairing reset. |

The roster response must distinguish invitation state from assignment state and return no phone ciphertext/digest, token/code digest, scanner session token, OTP proof, or attendee data. Authorized create/resend/reset responses return the one-time token, short code, and a ready-to-share pairing URL; the token is carried in the URL fragment, never its path or query. These responses use no-store headers. Replaying a create idempotency key must not create a second invitation or delivery; if the original secret is no longer safely available to return, the API offers the explicit rotate/resend operation rather than reconstructing or logging it.

Pair redemption is one transaction with a row lock on the invitation and uniqueness constraints that prevent multiple operators/devices from claiming the same invitation. Exact redemption retries return the same safe paired state and must not mint additional active assignments or sessions. A pairing retry must not reveal a previously issued plaintext session token; the client can resume only while it retains the token, otherwise an authorized recovery flow rotates/reissues the session. Session renewal, if needed, requires a live assignment and must not change the event/device binding.

After pairing, all scanner API requests—including `/scanner/events/:event_id/sync`, `/scan_uploads`, `/lookups`, and `/verifications`—send only `Authorization: Bearer <scanner_session_token>`. Scanner-specific authentication resolves the session and its event-staff assignment, device assignment, device, operator, and zone scope with a bounded eager-loaded lookup (no N+1); an exact one-SQL-query implementation is not part of the API contract. The scanner context exposes `current_scanner_operator` so controllers/services can attribute scans without depending on a normal `current_user` JWT. Scanner endpoints must not also require a normal Core JWT or `X-Scanner-Token`. Replace/remove the existing dual-token `/scanner/auth` flow and the separate device token (`token_digest`, `X-Scanner-Token`, `RotateToken`, and rotation route); do not retain a compatibility path in this pre-launch redesign.

## Authorization, abuse controls, and audit

- Only an authorized event owner/admin/manager with the existing ability to assign `scanner` may create, resend, list, or revoke invites for that event. Scanner users cannot invite or manage other scanners.
- Enforce organization/event ownership at every route; IDs from another event or organization return a non-disclosing not-found/forbidden response consistent with existing policy conventions.
- Require idempotency keys for mutations. Bind replay to actor, event, and canonical request digest; changed phone, zones, or access window under the same key is an idempotency conflict.
- The short code is six digits, single-use, and expires 10 minutes after issue. Permit at most three pairing attempts per PWA installation in that window, with an additional per-source IP throttle; a throttled/consumed code requires organizer-authorized rotation. The pairing request already carries a generated installation identifier, so staff do not enter an additional ID. The code and high-entropy link/QR token are alternative capabilities for the same invitation revision. Do not infer remote versus on-site use; enforce the same limits everywhere.
- Use constant-time digest comparisons where applicable. Do not put bearer credentials in URL query strings; magic-link handling should place the secret in a fragment or exchange it immediately in a POST body, then remove it from browser history/referrer context. A QR is an organizer-authorized capability, not cryptographic proof that the claimant is physically at the venue; its one-time use, finite invitation expiry, and event scope bound forwarding risk.
- Audit create, delivery outcome, resend/rotation, claim, failed/throttled redemption, event revoke, device revoke, and expiry. Audit metadata contains IDs, actor, invitation revision, method, and safe status only—not phone, code, link token, OTP, or note.
- Device/event/session revocation blocks the next online scanner request. Reusing the existing staff-revoke URL must trigger scanner-session denial and close the linked scanner-device assignment through a Ticketing-aware orchestration boundary; the Ticketing command may invoke the existing Events revoke command, but do not introduce an `Events` → `Ticketing` dependency. Keep scan history immutable and reconcile previously uploaded/offline attempts using the established rules.

## Expiry, zones, and offline behavior

- Invitation expiry is finite and configurable, with a default suitable for the event's staffing window; an unclaimed invitation expires without creating a staff assignment or device assignment.
- On claim, scanner access defaults to the latest scheduled event-date end plus six hours. The exact UTC end is stored on the event-scoped assignment/session. Missing schedule end requires an explicit finite override.
- Event cancellation revokes pending invites, active event assignments, and scanner sessions. Rescheduling does not silently extend a previously issued session; the organizer must review/update scanner access windows. The implementation must make the stale window visible in the roster and tests.
- `all_current_zones` snapshots current access-zone IDs at activation. A zone created later is excluded until an organizer updates the assignment. Selected-zone mode stores only selected IDs. Empty means no zone access.
- While connected, revoked sessions fail on the next request. While offline, the PWA may continue against its synchronized snapshot only until local expiry; a later sync applies revocations and updates. This is an explicit consistency boundary, not a backend defect.
- Preserve the current sync apply order, cursor-last transaction rule, ticket credential contract, local `client_scan_id` idempotency, and server-authoritative upload reconciliation. Pairing must not introduce a second QR admission validator or include attendee notes/answers/consent evidence in scanner snapshots.

## Compatibility and non-goals

- Replace the organizer's UUID entry path for new scanner assignments; do not retain it as a parallel UX or add a public API that requires the organizer to know an internal user ID.
- Do not introduce global `ORGANIZER` promotion, passwords for gate staff, app-store installation requirements, or a second ticket-validation contract.
- Do not promise that a disconnected scanner can be remotely terminated immediately.
- Do not build an SMS provider adapter inside Ticketing. Use the existing outbox/notification ownership boundary: persist encrypted delivery material, enqueue only invitation ID/revision, and let the provider-injection delivery job send it. Messaging/provider integration remains an explicit dependency if the shared delivery seam is not yet available.
- Do not expose raw attendee records offline beyond the already approved scanner-sync projection.
- Resend rotates the invitation capability; it does not create another event staff assignment or scanner device.

## Acceptance criteria

1. An organizer can invite by a valid phone number and optional label without entering a UUID; invalid/ambiguous phone input fails safely.
2. Only authorized event staff managers can invite/revoke scanner access, and the resulting role is event-scoped `scanner`; no global role is added.
3. The invitee claims the invite using a valid link/QR token or short code without a second OTP. Pairing does not mark the phone verified or imply the redeemer's natural-person identity. Replaying redemption does not create duplicate assignments, devices, sessions, or deliveries.
4. Magic link, QR, and short code are single-use/revision-bound and expire. The code expires within 10 minutes and allows no more than three failed attempts, with additional rate limits. Resend invalidates old material.
5. The claimed scanner session is bound to the invitation's operator record, one event, one device, one assignment, zones, and a finite expiry; it cannot call general organizer or finance APIs. Every scanner call uses one Bearer token, not a user JWT plus device token.
6. The organizer roster accurately distinguishes queued/delivered/failed invites from paired/revoked/expired access and shows only masked phone and safe operational fields.
7. Event-scoped revocation does not revoke unrelated event assignments; device-wide revocation does. Both block connected requests and preserve immutable scan/reconciliation history.
8. Offline scanning continues under the existing scanner contract; offline revocation limits are documented and tested, and synchronization applies the revoke when the device reconnects.
9. No raw phone, pairing token/code, scanner-session token, staff note, or attendee PII leaks to logs, outbox arguments, audit metadata, serializers, or unrelated API responses. Invitation redemption never changes phone-verification state.
10. Existing ticket transfer, admission, scanner sync, scanner upload, and device-management behavior remains intact except where scanner authentication deliberately adopts the scoped session contract.
11. API routes, request/response examples, and error cases are synchronized in `postman/Digis API_collection.json` and documented for frontend integration.

## Required implementation test matrix

- Phone normalization, existing/new operator resolution, capability-method attribution, explicit unverified-phone state, and no global-role side effect.
- Authorization across event owners/managers/scanners, cross-organization IDs, and event-scoped policy visibility.
- Invitation create/replay/changed-payload conflict; duplicate phone invite policy; resend rotation; revoked/expired/replayed link and code.
- Six-digit code expiry at 10 minutes, third-failure rejection, per-source/invitation throttling, successful code/link claim races, and exactly-one winner under concurrent redemption.
- Atomic binding among invitation, operator, device, event staff assignment, device assignment, zones, and scoped session; failures roll back all partial records.
- Session cannot access unrelated events, admin/organizer/finance/attendee endpoints; session expiry and event/device/assignment revocation block online access. Scanner endpoints accept the scoped Bearer token and reject the legacy dual-token contract.
- SMS outbox/job delivery success, provider rejection/exception, retry with same delivery revision, resend supersession, and no secret in job arguments/logs.
- Zone snapshot and selected-zone enforcement, including empty zones and zones added after pairing.
- Event cancellation and rescheduling/window review; invitation expiry and session expiry at event end plus grace period.
- Offline device behavior before and after revocation sync; duplicate scan/upload replay and reconciliation continue matching the native contract.
- Roster query behavior under `N_PLUS_ONE=1`, bounded scan-count aggregation, serializer visibility/privacy assertions, and controller/Postman contract tests.

## Implementation notes

- Add exactly one new migration per new table: `ticketing_scanner_invitations` and `ticketing_scanner_sessions` must be created in separate migration files. Fold `event_staff_assignment_id` into the original `20260812090014_create_ticketing_scanner_device_assignments.rb` migration; derive the operator through that association instead of duplicating its ID. Remove the obsolete device-token column from the original scanner-device migration, then remove its model/service/controller/route/tests. Update the schema snapshot.
- Reuse existing phone normalization, audit, outbox, idempotency, scanner sync, and policy mechanisms instead of cloning them. OTP is not part of the initial pairing flow; do not call the existing user-bound phone-verification proof as a hidden pairing prerequisite.
- The approved implementation plan verifies the minimal operator-record lifecycle and shared outbox delivery seam, then splits the work into schema, invitation/API, delivery, capability redemption and single-token session, roster/revocation, and scanner sync/auth regression stages.
- Any change to scanner auth/session claims or sync payload must update the scanner contract docs/fixtures and be tested against the current native contract. Keep frontend PWA IndexedDB/session restoration work as a separate frontend deliverable with this API spec as its contract.
