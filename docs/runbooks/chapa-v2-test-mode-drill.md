# Chapa V2 Test-Mode Drill

Use this runbook after adding Chapa V2 test credentials to the local/Render
secret store. Never paste keys or webhook secrets into chat, source control, or
logs.

## Operator setup

Set these values in the deployment environment:

- `CHAPA_ENABLED=true`
- `CHAPA_PAYOUT_ENABLED=true` when payout testing is intentional
- `CHAPA_MODE=test`
- `CHAPA_SECRET_KEY=CHAPA_TEST_...`
- `CHAPA_WEBHOOK_SECRET=<dashboard webhook secret>`
- `CHAPA_API_BASE_URL=https://api.chapa.global`
- `CHAPA_CALLBACK_URL=<deployed callback URL>`
- `CHAPA_RETURN_URL=<deployed return URL>`

Configure the V2 payment/refund webhook endpoint in the Chapa dashboard:

```text
POST https://<app-host>/payments/chapa/webhook
```

Enable payment and refund events for this endpoint. The payout-specific webhook
ingress is a separate follow-up because payout events must be routed to Finance
and Marketplace payout reconciliation rather than the Orders payment inbox.
Until that ingress is deployed, use the V2 payout verification endpoint and the
existing reconciliation jobs for payout state recovery.

The endpoint must receive the exact raw body and `x-chapa-signature` header.

## Smoke sequence

1. Initialize one hosted ETB payment and confirm the response contains only a
   pending checkout session, never a fulfillment decision.
2. Complete a test checkout and verify the payment server-side using the V2
   payment reference.
3. Replay the initialization with the same `Idempotency-Key`; confirm the same
   provider attempt is returned and no duplicate payment is created.
4. Send/receive a duplicate `payment.success` webhook; confirm one durable
   payment event and one fulfillment effect.
5. Exercise a failed, cancelled, incomplete, blocked, and auth-needed payment
   fixture. Confirm each state remains non-fulfillable.
6. Run one direct-charge test for Telebirr or CBE Birr when the dashboard
   account exposes that test method. Confirm authentication and verification.
7. Validate the V2 ET bank list and the bank slug used by the encrypted payout
   destination.
8. Create one V2 payout in test mode. Confirm initialization returns a pending
   or processing state and store both `merchant_reference` and
   `chapa_reference`.
9. Verify the payout and process `payout.success`, `payout.failed`,
   `payout.blocked`, and `payout.reversed` webhooks idempotently.
10. Replay the same payout request with the same `Idempotency-Key`; confirm no
    second provider payout is created.

## Deferred capability checks

Do not enable split payments or virtual accounts as product dependencies until
the V2 test key proves all of the following:

- subaccount creation and reuse in test mode;
- a split hosted payment and refund behavior;
- virtual-account creation with duplicate-key replay;
- virtual-account deposit, deduction, insufficient balance, and history;
- test/live mode isolation for every webhook.

## Evidence to record

Record only non-secret evidence: endpoint, HTTP status, internal idempotency
key, merchant reference, Chapa reference, normalized status, and timestamps.
Mask account numbers, emails, phone numbers, request bodies containing
beneficiary data, and provider secrets.
