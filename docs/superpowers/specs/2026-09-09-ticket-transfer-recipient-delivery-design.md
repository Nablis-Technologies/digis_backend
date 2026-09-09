# Ticket Transfer Recipient Delivery and Guest Acceptance

## Goal

Allow an owner to transfer a ticket to an existing verified user or to a
phone-backed shadow user, with secure SMS/email delivery and OTP acceptance.

## Contract

- Initiation remains authenticated and owner-scoped. Phone is required; an
  existing recipient email is used when present.
- The transfer stores only a digest for lookup and an encrypted delivery token
  for the server-side delivery job. Raw tokens never cross outbox or queue
  boundaries.
- `ticketing.ticket_transfer.initiated` is handled by a bounded delivery job.
  SMS and email use the existing provider registry; missing providers remain
  observable without changing ticket ownership.
- Branded transfer URLs use the existing `Links::ShortLink` resolver with a
  `ticket_transfer` target. Resolution decrypts the token only to construct the
  public landing URL.
- Public landing and OTP endpoints validate the token, pending status, expiry,
  and masked recipient identity. They never expose a full phone, token, or
  provider credentials.
- Existing verified recipients keep the authenticated accept route.
- Shadow or unverified recipients use transfer-bound OTP. Acceptance changes
  ownership and creates a new credential generation atomically. Without a
  password, the recipient remains passwordless and receives a signed ticket
  view; with a password, the user is verified and receives JWTs.
- All mutating endpoints require `Idempotency-Key`; replay returns the original
  outcome and never creates another generation or delivery.

## Safety boundaries

Committed or otherwise mixed credential states fail closed. A transfer cannot
be accepted after cancellation, expiry, cutoff, suspension, revocation, or a
credential-generation change. The original owner cannot accept their own
transfer.

## Verification

Cover existing-account acceptance, shadow OTP acceptance, delivery retry and
provider absence, branded-link redirect, idempotent replay, expiry/cutoff,
wrong-recipient proofs, and privacy-safe serializers in focused and full Rails
suites.
