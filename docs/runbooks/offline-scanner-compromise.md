# Offline scanner compromise

## Operating boundary

- Owner: Ticketing security/on-call and event operations.
- Treat a lost or stolen device as compromised until its event/device access is
  revoked. A disconnected scanner may continue against its last synchronized
  offline projection until it reconnects or its local session expires.
- Scanner sessions are event-scoped bearer credentials. They are stored as
  keyed digests and cannot be recovered from the database or replayed from a
  plaintext device token.

## Detect

Review the scanner roster, device last_seen_at, active event assignments,
session expiry/revocation, scan uploads, and audit evidence. Reconcile
unuploaded offline scans before declaring the incident fully contained.

## Immediate action

1. Identify the device, organization, event assignments, last sync versions,
   and possible exposure window.
2. For a lost or stolen device, revoke the whole device with
   POST /scanner_devices/:id/revoke, an Idempotency-Key, and a required
   reason. This revokes all active device assignments and bound sessions in
   one transaction. Every subsequent online scanner request is denied.
3. If the device is safe but its PWA session was lost, use the event roster's
   POST /scanner_invitations/:id/reset_pairing recovery action. It revokes the
   old assignment/session and rotates the invitation capability while
   preserving the event-owned scanner staff grant. Pair the replacement
   installation through POST /scanner/pair; the old session token is never
   revealed again.
4. If the scanner operator's event role must be removed, use the existing
   event-staff POST /events/:event_id/event_staff_assignments/:id/revoke route
   with an Idempotency-Key. The next connected scanner request is denied from
   the authoritative Events assignment state; a Ticketing outbox handler then
   closes the linked device assignment and sessions.
5. If the event is cancelled, scanner authorization is denied immediately by
   event state. Durable outbox cleanup revokes pending invitations and all
   paired scanner sessions/assignments.
6. If signing-key compromise is suspected, follow
   [security-key-rotation.md](security-key-rotation.md) and treat cached,
   disconnected scanners as untrusted until synchronized.

## Prohibited action

- Do not try to rotate or recover a device token; that authentication scheme
  has been removed.
- Do not place a pairing token, pairing code, scanner session token, QR token,
  private signing seed, or attendee payload in a ticket, log, audit metadata,
  or job argument.
- Do not edit revocation or attendee-index rows directly to hide a scan.
- Do not promise an instant offline kill switch. Offline devices can retain
  their existing synchronized snapshot until connectivity returns or local
  session expiry.

## Diagnostics

Discover devices for an organization as an authorized owner/admin or platform
administrator with GET /organizations/:organization_id/scanner_devices.
Responses include safe lifecycle fields only; session digests and pairing
material are never serialized.

For database diagnostics, inspect the device row, assignments including their
event_staff_assignment_id, and sessions' expiry/revoked timestamps. Never
select or print scanner token digests, invitation ciphertext, pairing
capabilities, or request headers.

## Recovery

Use the organizer API/UI to revoke the compromised device or reset one
invitation's pairing. A newly paired PWA receives a new scanner_session_token
once; persist it in the PWA's secure local session storage. Subsequent sync,
lookup, verification, and upload calls send only
Authorization: Bearer <scanner_session_token>.

Relevant management routes:

- GET /events/:event_id/scanners — shows invitation and assignment state.
- POST /scanner_invitations/:id/reset_pairing — rotates an invitation's
  pairing capability and invalidates the prior device assignment/session.
- POST /events/:event_id/event_staff_assignments/:id/revoke — revokes the
  authoritative event role and publishes Ticketing cleanup for scanner roles.
- POST /scanner_devices/:id/revoke — revokes the whole device and every bound
  active session/assignment.

## Staging drill

Pair a scanner, call sync using only the returned scanner bearer, revoke the
event staff assignment, and verify the old bearer is denied immediately and
the cleanup outbox revokes its device assignment/session. Reset another
invitation, pair a replacement installation, and verify the previous bearer
still fails while the new bearer can sync. Finally, disconnect a paired
scanner, revoke access, and confirm the operator guidance accurately explains
that the offline snapshot is usable only until reconnect or local expiry.
