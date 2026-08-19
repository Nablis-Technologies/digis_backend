# Offline scanner compromise

## Operating boundary

- Owner: Ticketing security/on-call and event operations.
- Severity: SEV-1 when a device or private key may be compromised; SEV-2 for a
  lost device with no evidence of credential extraction.
- Authority: Organization administrator or platform administrator may rotate a
  device token. Platform security decides whether gates require online
  validation.

## Detect

Use scanner authentication failures, unexpected `last_seen_at`, duplicate or
out-of-scope scan uploads, operator reports, and audit events. A disconnected
device may continue using its last synchronized public keys and revocation
projection until it reconnects.

## Immediate action

1. Identify the device, organization, event assignments, last sync versions,
   and possible exposure window.
2. Stop assigning the device to a gate and require online validation for the
   affected gate if the event is high security.
3. Rotate the device token through `Ticketing::Scanners::RotateToken` using an
   authorized organization/platform administrator. Deliver the new plaintext
   token only through the approved secure channel.
4. If signing-key compromise is suspected, follow
   [security-key-rotation.md](security-key-rotation.md) and treat cached,
   disconnected scanners as untrusted until synchronized.

## Prohibited action

- Do not place a scanner token, QR token, private signing seed, or attendee
  payload in a ticket, log, or job argument.
- Do not edit revocation or attendee-index rows directly to hide a scan.
- Do not assume a signed QR is fresh while the device is disconnected.

## Diagnostics

```bash
DEVICE_IDENTIFIER="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
device = Ticketing::ScannerDevice.find_by!(device_identifier: ENV.fetch("DEVICE_IDENTIFIER"))
puts device.attributes.slice("id", "organization_id", "device_identifier", "status",
  "last_seen_at", "revoked_at").inspect
puts device.assignments.order(created_at: :desc)
  .pluck(:id, :event_id, :status, :last_synced_at, :last_revocation_version,
         :last_attendee_index_version).inspect
'
```

## Recovery

Rotate the device token with an authorized actor:

```bash
DEVICE_ID="..." ACTOR_ID="..." PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner '
device = Ticketing::ScannerDevice.find(ENV.fetch("DEVICE_ID"))
actor = Core::User.find(ENV.fetch("ACTOR_ID"))
result = Ticketing::Scanners::RotateToken.call(device:, actor:)
raise result.error unless result.success?
puts "New scanner token must be delivered through the secure operator channel."
'
```

The repository currently has a token-rotation command but no dedicated
device-revocation command/API. A compromised device therefore remains an
operational gap: revoke/suspend it through the approved device-management
surface before production, or require online validation until that surface is
available. Do not substitute raw SQL.

After recovery, authenticate the replacement device, download a full or delta
sync, and acknowledge cursors only after the scanner commits its local
transaction.

## Communication and verification

Event operations owns gate instructions; Ticketing security owns the incident;
Support communicates any attendee impact. Verify token rotation audit evidence,
device authentication failure for the old token, current signing keys,
revocation versions, and scan-upload reconciliation.

## Staging drill

Authenticate a device, rotate its token, submit an old-token request, revoke a
credential while the simulated scanner is disconnected, reconnect it, and
apply the delta. Confirm the old device token fails, the stale offline window
is documented, and the synchronized scanner rejects the revoked credential.
