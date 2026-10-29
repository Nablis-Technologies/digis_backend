# Messaging Preview Provider Runbook

The preview provider lets the Render preview service exercise the real SMS/email campaign delivery path without contacting an external vendor. It returns provider-neutral `DeliveryResult` values and never stores or sends message content.

## Safety boundary

The adapter is registered only when both conditions are true:

```text
RENDER_PREVIEW=true
DIGIS_MESSAGING_PREVIEW_PROVIDER=true
```

If `DIGIS_MESSAGING_PREVIEW_PROVIDER=true` is set outside a Render preview, application boot fails closed. Do not set this flag on a live production service.

## Render configuration

Set these service variables, then deploy the commit containing the preview-provider code:

```text
DIGIS_MESSAGING_PREVIEW_PROVIDER=true
DIGIS_MESSAGING_PREVIEW_OUTCOME=delivered
```

For a private Render preview frontend smoke test, you may additionally set:

```text
DIGIS_PREVIEW_DEBUG_LOGGING=true
```

This opt-in flag is accepted only when `RENDER_PREVIEW=true`. It registers the
preview OTP sender and logs OTP challenge IDs/codes plus preview SMS bodies,
without recipient phone numbers. Disable it immediately after testing and
never set it on a live production service.

`DIGIS_MESSAGING_PREVIEW_OUTCOME` is allowlisted:

| Value | Delivery behavior |
| --- | --- |
| `delivered` | Delivery succeeds and consumes the reserved credit. |
| `sent` | Delivery succeeds with a sent (not delivered) status and consumes the credit. |
| `failed` | Permanent provider failure; delivery is failed and the credit is refunded. |
| `retryable` | Retryable provider failure; delivery remains pending and the credit stays reserved until retry or exhaustion. |

The outcome is service-wide and environment-controlled, not request-controlled. Change it only on the preview service and redeploy before running that scenario.

## Campaign smoke flow

Use the normal organizer API flow:

1. Create or append a contact list.
2. Create an SMS or email campaign.
3. `POST .../estimate` until the response is `status: "ready"`.
4. `POST .../attest` with the organizer confirmation.
5. `POST .../launch` with the returned quote identity.
6. Observe campaign and delivery status, then verify the credit ledger outcome.

No SMS or email is sent by this adapter. A real vendor sandbox test is still
required after an SMS/email provider is selected and registered.

## Disable after testing

Set `DIGIS_MESSAGING_PREVIEW_PROVIDER=false` (or remove it) on the preview service and redeploy. The application then returns to the normal missing-provider behavior for SMS/email while retaining the in-app provider.
