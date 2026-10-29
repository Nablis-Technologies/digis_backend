# Ticket QR signing-key rotation

This runbook rotates the server-side Ed25519 keys used to sign ticket QR
credentials. The private seeds stay in the deployment secret store. Scanners
receive only the corresponding public keys through the scanner snapshot/delta
contract.

## Configuration

The application reads:

- `TICKETING_QR_SIGNING_KEYS`: a JSON object mapping key IDs to Base64-encoded
  32-byte Ed25519 seeds.
- `TICKETING_QR_CURRENT_KID`: the key ID used for newly issued credentials.

Development and test use a deterministic application-derived key. Production
must provide both variables through the secret manager; never commit seeds,
place them in logs, or include them in scanner bundles.

## Normal rotation

1. Identify the last valid credential expiry, the maximum scanner offline
   window, and every active scanner assignment. The retirement point must be
   later than both the last old-key credential expiry and the required scanner
   synchronization window.
2. Generate a new random 32-byte seed in the secret manager. Assign it a new,
   never-reused key ID.
3. Deploy a configuration containing both the current key and the new key,
   while leaving `TICKETING_QR_CURRENT_KID` on the old key. This activates the
   new public key for scanners without changing newly issued credentials yet.
4. Confirm the scanner snapshot and delta responses contain both public keys.
   Connected scanners must complete a full or delta synchronization before
   their gate opens. A download does not acknowledge a cursor; the scanner
   commits the cursor only after its local transaction succeeds.
5. Change `TICKETING_QR_CURRENT_KID` to the new key ID and deploy. New
   credentials now use the new key, while the old key remains available for
   verification during the grace period.
6. During the grace period, monitor credential expiry, scanner synchronization,
   and unknown-key verification failures. Do not delete the old key while an
   old-key credential can still be valid or while an assigned scanner may be
   disconnected.
7. After the grace conditions are satisfied, deploy a key set containing only
   the new key. The old key is now retired; old signed tokens fail with the
   `unknown_qr_key` decision even if their envelope has not been modified.

## Emergency compromise

If an old private seed may be compromised, remove it from the verification set
as soon as operationally required, switch issuance to a new key, and require
online validation or a completed scanner synchronization for affected gates.
This can invalidate otherwise unexpired old credentials. Record the incident
and the affected key ID in the security incident system; do not record the
seed or QR token.

## Offline limitation

Ed25519 proves who issued a credential, not that a disconnected scanner has the
latest revocation or key set. A scanner that has not synchronized can
temporarily accept a still-valid old credential or miss a recent revocation.
Gate procedures therefore synchronize signing keys, package/generation
revocations, credential revocations, attendee-index deltas, and schedule
versions before opening. High-security delegated or emergency rotations must
use online validation until the assignment acknowledges the new versions.

## Rollback

If the new key deployment is unhealthy, restore issuance to the previous key
only while retaining every key that has signed a still-valid credential. Never
remove the new key merely because issuance was rolled back; first determine
whether any credential was issued with it. Re-run the normal synchronization
and retirement checks before deleting either key.
