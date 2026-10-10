# Organization and Event Staff Invitations

**Status:** Approved for implementation; no code implementation has started.

## Goal

Replace organizer-facing UUID-based staff addition with invitations addressed to an email address or phone number. An invitation is not access: the recipient must authenticate or sign up, verify the invited contact, and explicitly accept before any organization membership or event assignment becomes active.

The API resolves the real Core user internally after claim. UUIDs remain internal identifiers and are never required from organizers.

## Current-state evidence

- Organization membership creation is nested under the owner-organization API and currently accepts a user UUID and role. The organization creator receives an active owner membership automatically.
- Event staff assignment creation accepts a user UUID and role and creates an active event assignment immediately.
- Organization roles are owner, admin, and staff. The membership API prevents assigning owner through ordinary member management; ownership transfer remains separate.
- Event assignments are event-scoped and have manager, staff, scanner, and contractor roles. Organization membership and event assignment are separate grants.
- Scanner invitations already use a phone-based, event-scoped claim and device-pairing flow. Scanner pairing must remain specialized because it provisions a device assignment and scanner session.
- Current scanner invitation delivery defaults to a no-op sender. A production-ready email/SMS invitation flow requires real delivery adapters and truthful delivery status.

## Product and security decisions

1. **Contact, not UUID, is the organizer input.** Accept exactly one of email or phone per invitation. The frontend may present one “Email or phone” field, but the API contract should identify the contact type explicitly rather than accepting a UUID fallback or guessing among several identity fields.
2. **Create pending invitations, not shadow users.** Invitation creation must not create a Core user, organization membership, or event assignment. This avoids active access before contact verification and acceptance, and avoids accumulating unclaimed shadow accounts.
3. **Claim is required for existing and new accounts.** Existing accounts do not get silently added. The authenticated claimant must control the invited contact, and must explicitly accept.
4. **Do not reveal account existence.** Create and delivery responses must not vary based on whether the contact currently matches a Core user. Do not expose a user lookup endpoint for organizers.
5. **Keep invitation ownership domain-scoped.** Organizations owns membership invitations; Events owns general event-staff invitations. Shared contact normalization, verification, and delivery utilities may live behind Core/Messaging boundaries, but Core must not decide organization/event roles or create those domain grants.
6. **Invitations are parent-owned durable grants.** Authority is checked when the invitation is created. The invitation remains valid if its creator later loses access, until accepted, explicitly revoked by an authorized current manager, or expired. Acceptance still checks the parent resource and requested role are valid. Event cancellation revokes its pending staff invitations.
7. **No global role promotion.** Accepting an organization or event invitation must not assign the global ORGANIZER role. Access comes only from the accepted domain membership/assignment.
8. **Scanner invitations remain specialized.** General event invitations do not provision scanner devices or sessions. Scanner access continues through the dedicated scanner invitation and pairing lifecycle.
9. **Delivery rolls out by channel.** Phase 1 supports phone invitations only. Email invitations remain disabled until an email delivery adapter and verified-email claim path are implemented.

## Proposed user flow

### Organizer flow

1. The organizer chooses **Organization team** or a specific **Event team**. The UI displays only roles the current actor may grant.
2. The organizer enters one email or phone and chooses a role. The UI never asks them to search for or paste a UUID.
3. The backend normalizes and validates the contact, checks role-grant authority, and creates a pending invitation with a finite expiry. No access is granted yet.
4. In Phase 1, the invitation is queued for SMS delivery. The response reports the invitation's pending state and truthful delivery state. An authorized creator may receive a one-time copy/share claim URL in the no-store mutation response; the URL is a secret and must not be serialized later or logged. Email delivery is added only in Phase 2.
5. The organizer can list pending invitations, resend (rotating the old capability), or revoke. The roster distinguishes pending invites from accepted members/assignments.

### Recipient claim flow

1. The recipient opens the invitation link. The capability is high entropy, single use, invitation-scoped, and carried in a URL fragment or exchanged immediately in a POST body—not in a query string or path.
2. The recipient signs in or signs up through the canonical account flow. In Phase 1, the authenticated account must have a verified phone that matches the normalized invitation phone. New accounts use the canonical phone-OTP signup flow. Existing accounts use the current phone-verification flow for their already-associated phone; an invitation must not silently change an account's phone or mark a different phone verified. In Phase 2, the equivalent verified-email match is required. The invitation token is not a substitute for account authentication or verified-contact state.
3. The UI shows the organization or event name, requested role, and inviter, then asks the recipient to accept. The recipient cannot change the scope or role while claiming.
4. On acceptance, the domain command locks and validates the invitation, resolves the authenticated Core user by the verified contact, creates the active membership or event assignment, marks the invite accepted, and records an audit transition atomically.
5. If the user already has the same active grant, acceptance is an idempotent no-op or a typed already-member result; it must not create duplicate records. A role change uses the existing authorized role-change flow, not implicit invitation acceptance.

## Scope and role rules

### Organization membership invitations

- Allowed target roles: admin and staff. Owner cannot be assigned through an invitation; ownership transfer remains a separate workflow.
- The current organization hierarchy applies at invitation creation: an owner may invite an admin or staff member; an admin may invite staff. Other actors cannot invite organization members.
- Acceptance creates only an active membership in that organization. It does not create event staff assignments for every event.
- Organization invitation management is authorized by the organization's current owners/admins, allowing an authorized manager to revoke an outstanding invitation created by a former manager.

### General event staff invitations

- Allowed general event roles: manager, staff, and contractor, subject to existing event assignment rules. The scanner role is excluded from this endpoint and remains available only through scanner invitations/pairing.
- A user may hold at most one active general event role (manager, staff, or contractor) per event. Claiming an invitation for a different general role returns a conflict; changing role uses the authorized role-change action. A scanner assignment is a separate specialized grant and may coexist with that one general role.
- An organization owner/admin or platform admin may invite only roles allowed by the current Events authorization policy. An event manager may invite staff; a manager cannot grant manager or contractor privileges.
- Acceptance creates only an event-scoped assignment. It does not create an organization membership.
- The create request may include `assignment_expires_at`; acceptance copies it to `Events::EventStaffAssignment.expires_at`. It is optional and is not the invitation's own seven-day claim expiry.
- Event cancellation revokes outstanding invitations. Invitation expiry and assignment access expiry are separate concepts.

## API contract proposal

Management endpoints are domain-scoped and never accept user_id as an alternate public input. Claim capabilities are sent only in request bodies, never in URLs.

Organization phone example (Phase 1):

    POST /organizations/owner/:organization_id/membership_invitations
    { "membership_invitation": { "phone": "+251911223344", "role": "admin" } }

Organization email example (Phase 2, disabled until email delivery and verification are ready):

    { "membership_invitation": { "email": "teammate@example.com", "role": "staff" } }

Event create example:

    POST /events/:event_id/staff_invitations
    { "staff_invitation": { "phone": "+251911223344", "role": "staff", "assignment_expires_at": "2026-10-12T18:00:00Z" } }

Organization claim:

    POST /organizations/membership_invitations/claim
    Authorization: Bearer <user_jwt>
    Idempotency-Key: <stable-client-key>
    { "token": "<64-character-capability>" }

Event claim:

    POST /events/staff_invitations/claim
    Authorization: Bearer <user_jwt>
    Idempotency-Key: <stable-client-key>
    { "token": "<64-character-capability>" }

Each create payload must contain exactly one of email or phone. Phase 1 rejects email invitations with a typed channel-not-enabled error. Create, resend, revoke, and claim requests require the standard Idempotency-Key header. Fields such as status, accepted_user_id, inviter_id, token, and user_id are server-owned and not permitted from the client.

Proposed actions:

- Create and list invitations under the organization or event scope.
- Resend a pending invitation, rotate its one-time claim capability, and enqueue delivery.
- Revoke a pending invitation.
- Accept through the authenticated, domain-scoped claim endpoints above. Each requires the verified contact matching that phase's invitation channel and the claim capability in the POST body.
- Retire the direct create action on organization memberships and event staff assignments; keep existing list/show/update/suspend/revoke actions where they remain meaningful. No compatibility shim is required.

### Roster read model

Use one request per scope to avoid forcing the frontend to coordinate membership and invitation requests, while keeping the underlying resources separate:

- Organization team roster: `GET /organizations/owner/:organization_id/team_roster` returns current memberships (active or suspended) and pending invitations in separate arrays, with independent pagination metadata for each array.
- General event staff roster: `GET /events/:event_id/staff_roster` returns current non-scanner event assignments (active or suspended) and pending general staff invitations in separate arrays, also with independent pagination metadata.
- Scanner assignments and scanner invitations remain on the existing scanner roster. Do not make Events depend on Ticketing merely to build a combined scanner/team response.

The response shape is conceptually `memberships: { data, pagination }` plus `invitations: { data, pagination }` for organizations, and `assignments: { data, pagination }` plus `invitations: { data, pagination }` for events. Invitation projections show masked contact, requested role, status, delivery state, and expiry; they never expose claim tokens. The roster is a read projection, not a polymorphic membership model. Mutations continue through the domain-specific invitation and membership/assignment endpoints. A pending-status filter on the existing memberships endpoint alone is not sufficient because pending invitations are separate resources.

## Invitation lifecycle and data protection

Each domain owns its invitation lifecycle and database table, with one new table per migration. Proposed states are pending, accepted, revoked, and expired. Delivery state is separate from invitation state.

Invitation records should capture the parent scope, requested role, inviter, accepted user when claimed, timestamps, invitation expiry, delivery revision/state, and idempotency/replay metadata needed by the repository's command conventions. Event staff invitations additionally retain the optional `assignment_expires_at` until claim.

Contact and capability handling:

- Normalize phone numbers to E.164 using the existing phone identity rules. Normalize email consistently without treating an unverified email as account proof.
- Include the contact channel/type in the keyed digest input so an email and phone value cannot alias. Enforce at most one pending invitation for a normalized contact in a scope with a partial unique index on the parent ID and contact digest where status is pending.
- Before creating an invitation, expire any overdue pending invite for the same scope/contact under the appropriate lock. The partial unique index is the concurrency backstop; map a uniqueness race to a safe duplicate-invitation response.
- Encrypt the destination at rest and use a keyed digest for scoped matching/deduplication. Never index or log plaintext contact values.
- Store only a digest of the high-entropy claim token for lookup; if asynchronous delivery requires recoverable token material, keep it encrypted and clear it after acceptance, revocation, or expiry.
- Audit metadata may contain invitation/user/scope IDs, role, status, revision, and actor IDs. It must not contain contact values, claim tokens, email/SMS contents, or one-time URLs.
- Set no-store/private response headers on one-time claim material. Filter email and phone parameters in logs.
- Return masked contact and safe lifecycle fields from roster/list endpoints. Never reveal whether an account existed when the invitation was created.

Expiry/retry defaults:

- Pending invitation default lifetime: 7 days, bounded by a configurable maximum.
- Resend rotates the token and increments the delivery revision; old links stop working. Resend does not extend the original expiry. An authorized manager must create a new invitation after expiry.
- Create, resend, revoke, and accept are idempotent. Replaying the same key and payload returns the prior result; same key with changed payload conflicts.
- Apply per-actor, per-contact, and per-source rate limits to creation, claim attempts, and resends. Do not allow a contact to accumulate unbounded pending invitations in one scope.

## Phased delivery and dependencies

- **Phase 1 — phone:** deliver and claim phone invitations using the canonical verified-phone account flow. Delivery is asynchronous and follows the existing outbox/notification ownership boundary. Jobs receive invitation ID and delivery revision, not plaintext contact or token arguments.
- **Phase 2 — email:** enable email invitations only after an email delivery adapter and email-verification/claim flow are available. Phone OTP does not verify email.
- Delivery states must distinguish queued, accepted by provider, delivered when provider receipts support it, failed, and unknown. Enqueuing a job is not proof of delivery.
- A real SMS provider adapter must be configured before declaring Phase 1 delivery ready. Core phone-verification request/verify logic exists, but its injected sender is preview-only by default; the Messaging preview adapter simulates SMS/email outcomes and does not send to a carrier or mailbox. The scanner invitation no-op sender is also not sufficient.
- If a real provider is unavailable in preview, an authorized organizer may receive a one-time copy/share claim URL in the no-store create/resend response. This is a manual fallback, not evidence that SMS was sent.
- Frontend/PWA implementation is a separate deliverable. The backend API and Postman collection define the contract.

## Errors and edge cases

- Invalid contact, both/neither email and phone, invalid role, or unauthorized inviter: typed validation/authorization error with no invitation created.
- Same contact already has a pending invitation for the same scope: return a safe typed conflict or the existing invitation only when replaying the same idempotency key; do not expose account existence.
- Expired/revoked/accepted capability or contact mismatch: generic invalid/expired claim response; do not disclose which check failed to an unauthenticated caller.
- Existing active membership/assignment: no duplicate grant. A different requested role requires a separately authorized role-change operation.
- Parent organization archived/deactivated, event cancelled/completed, or requested role no longer valid: reject or invalidate the pending claim without creating a grant.
- Concurrent claims: row-lock the invitation; at most one acceptance creates the membership/assignment and audit transition.

## Alternatives considered

1. **Resolve contact directly to a Core user and grant immediately.** Rejected: requires an account lookup, fails for new users, can reveal account existence, and grants access before the recipient verifies/accepts.
2. **Create shadow Core users and attach active roles.** Rejected: violates the claim-before-access rule, creates unclaimed identity records, and couples account lifecycle to organizer input.
3. **One generic Core invitation aggregate that assigns both organization and event roles.** Rejected: Core would own domain authorization and depend on Organizations/Events concepts, weakening module boundaries.
4. **Domain-owned invitations with shared contact/verification/delivery primitives.** Recommended: preserves domain-specific authorization while presenting consistent email/phone UX.

## Acceptance criteria

1. Organizers can invite by email or phone without a UUID, for both organization and event scope.
2. Invitation creation does not create a user, active membership, or active event assignment.
3. No access is granted until the invitee authenticates/signs up, verifies the invited contact, and accepts.
4. Existing and new accounts use the same claim rule; account existence is not disclosed by create responses.
5. Organization and event role hierarchies remain separate; no global ORGANIZER role is assigned.
6. Scanner invitations continue to create only scanner-scoped event/device access through the dedicated pairing flow.
7. Expiry, resend rotation, revoke, replay, duplicate, and concurrent claim behavior are covered with service and API tests.
8. Contact/token privacy holds across database, logs, audits, jobs, serializers, and API responses.
9. Email and SMS delivery semantics are truthful; no adapter is reported as delivered merely because the job was queued.
10. Existing direct UUID create endpoints are retired without backward-compatibility shims, and Postman/frontend contract docs are updated.

## Approved decisions

- Use a seven-day pending invitation lifetime; resending rotates the token without extending expiry.
- Pending invitations remain parent-owned if the creator loses their role, until an authorized parent manager revokes them or they expire.
- General event staff invitations allow manager, staff, and contractor according to role-grant authority; scanner remains on the specialized scanner-pairing path.
- Event role cardinality is explicit: one active general role per event/user, with a scanner assignment allowed independently; permissions resolve manager before scanner before other general roles for legacy multi-assignment rows.
- Phone claim requires the authenticated account's verified phone to match the invitation destination. An account with a different phone must use the canonical identity flow to change and verify its phone before claiming.
- Phase 1 is phone-only and requires a real SMS provider before automatic delivery is declared ready. Email verification and delivery remain Phase 2.
- Roster projections return current memberships/assignments and invitations in separate arrays with independent pagination metadata.
