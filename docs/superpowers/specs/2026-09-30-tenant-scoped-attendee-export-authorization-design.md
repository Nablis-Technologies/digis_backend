# Tenant-Scoped Attendee Export Authorization

## Problem

Private attendee exports currently require global `attendee_export.request` and
field permissions in addition to event-management authority. A legitimate
organization owner/admin or event manager can therefore manage the event but
cannot request a standard export unless someone grants a platform-wide role.
Granting the broad global `ORGANIZER` role to represent tenant membership is
unsafe because its permissions are not tenant-scoped.

## Decision

Keep `Core::Role` for platform-wide grants. Do not auto-promote users to
`ORGANIZER`, mutate roles from `GET /auth/me`, or backfill tenant members with a
global role.

For attendee exports, the event-scoped authorization resolver is the base
capability gate:

- An active primary-organization owner/admin, active co-organizer
  organization owner/admin, or active event manager may request standard
  attendee fields only for events they can manage.
- Contact fields (registration user's email/phone) are available to active
  primary/co-organizer organization owners/admins. A separately granted
  `attendee_export.contact` platform permission remains an explicit override,
  but never bypasses event manageability.
- Dietary and accessibility fields remain gated by their explicit
  `attendee_export.dietary` and `attendee_export.accessibility` permissions.
- Staff/scanner assignments do not gain export access from assignment alone.
- Create, generation, show, and download continue to recheck current event and
  field authorization; revoking or suspending membership removes tenant-derived
  access.

The frontend should use organization-scoped membership/context data for tenant
navigation and capability hints. No global organizer boolean is introduced by
this backend change, and frontend authorization remains presentation-only.

## Scope

Change `Ticketing::AttendeeExportPolicy`, `Ticketing::Exports::FieldRegistry`,
their policy/registry tests, and the authenticated attendee-export integration
tests. Remove the now-redundant standard-request
permission from the seeded global `ORGANIZER` role and its test fixture, while
retaining its explicit contact permission. Update the prior attendee-export
design's permission-model section to point to this decision. Do not alter
organization creation/promotion, export routes, serializers, schemas, Postman,
or the frontend repository.

## Acceptance Tests

- An authenticated organization owner/admin with only the default `USER`
  platform role can request a standard export for their manageable event after
  reauthentication and with an idempotency key.
- Active event managers can request standard exports but cannot access contact
  fields without the explicit contact permission.
- Active primary/co-organizer owners/admins can access contact fields; inactive
  co-organizer links and suspended/demoted memberships do not grant access.
- Dietary/accessibility fields remain explicitly permission-gated.
- A global export permission never grants access to an event the actor cannot
  manage; staff/scanner assignments remain denied.
- Existing requester-only visibility, current-authorization rechecks,
  idempotency, proof consumption, and platform-admin behavior remain intact.
