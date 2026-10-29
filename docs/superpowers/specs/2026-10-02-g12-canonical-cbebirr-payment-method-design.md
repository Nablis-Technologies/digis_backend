# G-12 Canonical CBE Birr Payment Method Design

**Date:** 2026-10-02

**Status:** Implemented and verified locally; frontend mapping and deployment pending

## Goal

Allow the order and billing payment-attempt flows to accept Chapa's canonical
`cbebirr` payment-method code without accepting the non-canonical `cbe` alias.

## Current gap

`Payments::Providers::Registration` advertises `cbebirr` in Chapa's capability
set, but `Orders::Payment::PAYMENT_METHODS` currently aliases
`Commercial::FeeComponent::PAYMENT_METHODS` (`telebirr`, `card`, `bank`).
`Orders::PaymentAttemptSupport` rejects `cbebirr` before the adapter's Chapa
capability check can run. The same shared allowlist is used by the billing
payment-attempt flow.

The front-end repository/call site is not part of this backend workspace. Its
contract is to send the provider's canonical `cbebirr` value; `cbe` is not
accepted as an alias.

## Design

1. Give `Orders::Payment` an explicit payment-rail allowlist that includes
   `cbebirr` alongside existing accepted rails. Keep the commercial fee
   component filter allowlist separate; those are different concepts, and its
   database constraint is not changed in this slice.
2. Preserve the provider capability check. Chapa accepts `cbebirr`; a provider
   whose capability set does not include it continues to return the existing
   `payment_method_unsupported` failure.
3. Persist the canonical string `cbebirr` on the payment attempt. Do not
   silently normalize `cbe` or other aliases.
4. Keep Chapa Hosted Checkout. Its documented flow lets Chapa choose the
   payment method on the hosted page; the existing client intentionally does
   not send the undocumented `preferred_payment_methods` shape. This change
   makes `cbebirr` a valid method value for the application/capability gate; it
   does not promise a CBE-only hosted page. Direct Charge and its PIN/OTP/USSD
   authorization flow remain out of scope.
5. Update API examples and tests to use `cbebirr` as the canonical value.

## Out of scope

- Adding a `cbe` alias or guessing frontend values.
- Switching Hosted Checkout to Direct Charge.
- Method-specific fee schedule values for `cbebirr`; the commercial fee filter
  set remains unchanged.
- Editing the front-end repository, which is not the writable project for this
  task.

## Acceptance criteria

1. Chapa payment-attempt model and command validation accept `cbebirr`.
2. The Chapa capability check remains authoritative; unsupported providers do
   not accept `cbebirr`.
3. The payment record stores `cbebirr`, while `cbe` remains rejected.
4. Both event payment and billing payment attempt validation use the same
   payment-rail contract.
5. Hosted checkout payload semantics do not change; no unverified preferred
   method field is added.
6. Postman examples document `cbebirr`, and focused tests cover both success
   and unsupported-method failure.

## Provider references

- [Chapa Direct Charge initiation](https://docs.chapa.global/docs/v2/direct-charge/initiate-payment) lists `cbebirr` as a supported payment method.
- [Chapa Hosted Accept Payments](https://docs.chapa.global/docs/v2/integrations/accept-payment) describes Hosted Checkout as choosing the payment method; its `preferred_payment_methods` field is optional, but its request-wire shape is not defined there.
