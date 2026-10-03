# G-45 Incoming Ticket Transfer Discovery Design

**Date:** 2026-10-02

**Status:** Implemented and verified locally; frontend integration and deployment pending

## Goal

Let a verified, authenticated recipient discover and accept an incoming ticket
transfer inside the app without receiving or storing the bearer transfer token
in an inbox/list response.

## Current gap

`Ticketing::Transfers::Initiate` already publishes
`ticketing.ticket_transfer.initiated`, and the ticketing outbox handler queues
the existing SMS/email `TicketTransferDeliveryJob`. However, the recipient has
no in-app incoming-transfer projection, and authenticated acceptance currently
requires the bearer token even when the caller is the transfer's recorded
recipient. Provider delivery remains adapter/configuration dependent.

## Design

Use the existing recipient-owned Messaging notification inbox as the
discoverability surface, rather than creating a second unbounded transfer
history endpoint. Extend the transactional notification registry to consume
the already-published initiation event and persist an `in_app`-only
`transfer_incoming` notification for `TicketTransfer#to_user`. The notification
row remains recipient-visible through the existing inbox even if the user's
in-app delivery preference suppresses its delivery row.

The notification projection may include only transfer ID, ticket ID, event ID,
event title, product name, and expiry. It must never include the encrypted
token, token digest, phone, email, or a transfer URL containing the bearer
token. Existing SMS/email delivery remains owned by
`TicketTransferDeliveryJob`; the new notification does not enqueue duplicate
external delivery.

Add an authenticated recipient-ID acceptance path on the existing transfer
accept action. The path resolves the transfer by ID scoped to
`to_user_id == current_user.id`, then calls the same locked acceptance state
machine. It still requires a verified recipient, pending/unexpired transfer,
current ticket generation, active ticket, and event transfer cutoff. Keep the
existing bearer-token acceptance path and public guest OTP acceptance path
unchanged.

## Alternatives considered

1. Dedicated incoming-transfer list plus authenticated accept-by-ID. This is
   valid but adds a separate list/projection surface and a recipient query on
   a transfer table that currently has no `to_user_id` index.
2. **Recipient-owned in-app notification plus authenticated accept-by-ID
   (selected).** It reuses the existing indexed notification inbox and the
   initiation outbox event, avoids exposing bearer credentials, and requires
   no new table or database migration.
3. Add an in-app notification without an authenticated action route. Rejected
   because recipients still could not act when they lacked the SMS/email link.

## Out of scope

- Replacing the existing public bearer-token / guest OTP flow.
- Returning a bearer token in notification data or the sender wallet.
- Changing ticket ownership, scan, QR, or credential semantics before
  recipient acceptance.
- Replacing or duplicating the existing SMS/email delivery job.

## Acceptance criteria

1. Dispatching a committed `ticketing.ticket_transfer.initiated` outbox event
   creates one recipient-owned `transfer_incoming` notification, replay-safe
   under the existing outbox and notification dedupe keys.
2. The new notification creates only an in-app delivery; it does not duplicate
   the existing SMS/email transfer job.
3. Notification data contains only allowlisted IDs, display labels, and
   expiry; no bearer token, token digest, recipient/sender phone, or email.
4. An authenticated verified recipient can accept by transfer ID without a
   bearer token; a different user cannot discover or accept that transfer.
5. The token-based authenticated and public guest OTP acceptance flows remain
   unchanged.
6. Postman documents the notification shape and authenticated accept path.
