# Frontend–Backend Gap Tracker

Date: 2026-09-10
Status: G-01 through G-03, G-04 through G-10, G-15, and G-20 through G-22 implemented and verified locally; G-15 and G-22 are also verified on the Render preview; G-03 Render redeploy pending; G-11 decision recorded and planned; G-12 through G-14 and G-16 through G-19 deferred

## Purpose

This document consolidates the two frontend integration reports:

- `BACKEND_GAPS (1).md`
- `BACKEND_GAPS (2).md`
- `BACKEND_GAPS (3).md`

The reports were compared with the current Rails routes, controllers, policies,
serializers, services, seeds, tests, and the deployed preview behavior.

Only unequivocally true backend gaps are in the active queue below. Partial,
conditional, frontend-only, stale, and informational findings are intentionally
deferred to a later decision pass.

## Active true backend gaps

| ID | Verdict | Priority | Gap | Current evidence | Why it matters | Next implementation outcome | State |
|---|---|---|---|---|---|---|---|
| G-01 | True — blocking | P0 | Paid registrations remain `pending_payment` after payment acceptance | `AcceptPayment`/`FulfillOrder` fulfill the order and issue from the order item, but no paid-registration transition writes `confirmed` | The registration remains active and can block later purchases; registration and order state disagree | Transition the linked paid registration to `confirmed` atomically with accepted payment/fulfillment, with idempotent audit evidence | Implemented — verified locally |
| G-02 | True — blocking | P0 | No buyer release/cancel path for abandoned pending registrations | `ReleaseCheckout` and `RestartCheckout` close/release orders but do not cancel the associated registration | A buyer who abandons a checkout can remain blocked by the active registration identity slot | Add a buyer-scoped, idempotent release command for eligible `pending_payment` registrations; release holds and preserve terminal evidence | Implemented — verified locally |
| G-03 | True — blocking | P0 | Marketplace seller payout destination registration is unsupported by Chapa | Marketplace seller accounts now persist encrypted Chapa bank details with a keyed digest, remain pending when preflight verification is unavailable, support audited admin verification, and dispatch direct `account_number`/`account_name`/`bank_code` fields through the shared Finance transfer client | Seller payout onboarding and dispatch now use the provider's actual direct-transfer contract without exposing credentials or falsely proving ownership from `/banks` | Keep seller destinations encrypted and verified/manual-reviewed before dispatch; retain ledger, reserve, idempotency, and reconciliation gates | Implemented — locally verified 2026-09-10; Render redeploy pending |
| G-04 | True — blocking | P0 | Signup has no server-side password/phone validation | `Core::UserAuthenticatable` uses `has_secure_password validations: false`; no password length/confirmation or phone-format validation is present | Client-side validation can be bypassed; malformed or weak accounts enter the system | Add model-level password length/confirmation and canonical Ethiopian phone validation with typed field errors | Implemented — verified locally |
| G-05 | True — blocking | P0 | Authentication endpoints have no brute-force throttling | No `rack-attack` or equivalent auth throttle exists in middleware/config | Unlimited login attempts weaken the otherwise sound token/authentication posture | Add atomic per-IP and per-identifier limits for login, signup, and refresh; return localized `429 rate_limited` responses | Implemented — verified locally |
| G-06 | True — blocking for accurate discovery pricing | P1 | Public event `price_from_minor` includes non-ticket extras | `Events::Public::EventListSerializer#price_from_minor` previously computed the minimum across every active event product instead of ticket products only | Discovery cards and price filters showed an amount that could be the price of an add-on rather than the cheapest ticket | Restrict the projection to active ticket products and add a regression fixture containing a cheaper non-ticket product | Implemented — verified 2026-09-09 |
| G-07 | True — degrading | P1 | Public products omit non-sensitive `requires_ticket` | `Catalog::Public::EventProductSerializer` exposes price/availability but not the product metadata flag | Frontend cannot reliably gate add-ons that require a ticket | Expose a dedicated boolean (preferred) or a narrowly allowlisted metadata field; do not expose all organizer metadata | Implemented — verified locally |
| G-08 | True — blocking for dynamic forms | P1 | No public registration schema for dynamic form questions/scopes | Public consent requirements exist, but registration-form questions, versions, response scopes, and validation rules are organizer-only | Frontend cannot render arbitrary event forms or correctly submit slot-coordinate answers | Add a public, event/ticket-type-scoped schema projection with published-version and privacy boundaries | Implemented — verified locally |
| G-09 | True — degrading | P1 | Resale browse has no reliable “my listings” discovery | `GET /resale_listings` returns the public shape and filters to active rows; seller identity is intentionally omitted | Sellers cannot rediscover their own active listings across devices or sessions | Add an owner filter or a seller-safe projection for the caller’s own rows without leaking seller identity to buyers | Implemented — verified locally |
| G-10 | True — degrading | P1 | Wallet ticket projection omits resale policy fields | `TicketWalletSerializer#ticket_type` only exposes identity/admission fields | The frontend cannot show resale eligibility, cap, cutoff, or max-resale information before submit | Add the five existing resale policy fields to the owner-only wallet projection; backend remains authoritative | Implemented — verified locally |
| G-15 | True — product requirement confirmed | P1 | Confirmed registrations incorrectly block repeat purchases | The registration uniqueness boundary and `Submit` lookup now exclude `confirmed`; the rebuilt Render preview accepts a second confirmed registration for the same buyer and ticket type | Buyers can start another purchase while the existing purchase-limit lock remains authoritative for cumulative capacity | Keep one blocking pending registration per product/date, allow new registrations after confirmation, and enforce the cumulative cap through the locked purchase-limit allocations | Implemented — verified locally and on Render preview 2026-09-10 |
| G-20 | True — degrading | P1 | Wallet tickets omit purchased non-ticket extras | `Ticketing::TicketWalletSerializer` now projects fulfilled order add-ons without payment/provider fields | Buyers can see extras purchased with a ticket after checkout | Owner-only `add_ons` projection is eager-loaded on both `GET /tickets` and payment refresh | Implemented — verified 2026-09-09 |
| G-21 | True — degrading | P1 | RSVP events have no submission endpoint | Public free RSVP now reuses registrations and tickets with guest OTP or authenticated submission | Public RSVP OTP and submit routes use the existing registration, capacity, confirmation, and QR issuance boundaries | Implemented — verified 2026-09-09 |
| G-22 | True — product requirement confirmed | P1 | Guest payment refresh lacked claim context for starting OTP/account claiming without the SMS link | Guest refresh now uses a guest-only ticket serializer that returns `registration_id`, signed `ticket_view_token`, direct `ticket_view_url`, and branded-or-fallback `short_url`; authenticated wallet refresh remains unchanged | The confirmation screen can open the signed public ticket view, request OTP, and submit the existing guest claim flow without depending on SMS delivery | Implemented — local + Render preview verified 2026-09-10 (view/OTP request passed; final claim check was Cloudflare-rate-limited) |

## Explicitly deferred to the next decision pass

These findings are not being treated as unequivocal implementation tasks yet:

| ID | Classification | Reason deferred |
|---|---|---|
| G-11 | Decision recorded | Guest/shadow checkout selected with immediate ticket issuance after payment. OTP/password claiming happens later; signed public ticket views expire at event end + 30 days. The first implementation slice is deployed and verified on the Render preview; live SMS-provider configuration and production smoke evidence remain pending. Transfer recipient delivery and shadow-recipient OTP acceptance are implemented in `docs/superpowers/plans/2026-09-09-ticket-transfer-recipient-delivery-implementation.md`. Unified phone-first dashboard auth and OAuth are intentionally separated into `docs/superpowers/plans/2026-09-08-unified-auth-oauth-implementation.md`. |
| G-12 | Partial | The frontend/backend `cbe` mismatch is real, but the correct fix may be frontend mapping to a provider-supported canonical method rather than adding `cbe` to shared backend enums. |
| G-13 | Partial | Public event-setting data is limited, but several requested fields are computed or sensitive and cannot be exposed by simply expanding the whitelist. |
| G-14 | Conditional | User `name` and self-service profile editing depend on product requirements; the current password-only profile surface is consistent with the reduced UI. |
| G-16 | Stale/partial | Generic consumer notifications, preferences, seller payout routes, and quote-time promotions now exist. Marketplace seller payout destination registration is implemented under G-03. |
| G-17 | Informational | Reserved slugs/history are future hardening, not a current integration blocker. |
| G-18 | Conditional | The current adapter is Chapa v1. A v2 adapter is needed only if the merchant receives v2 keys. |
| G-19 | Frontend-only | Audience authorization is implemented server-side; remaining work is threading the proof through the frontend UI/request. |

## Already resolved or superseded

The following report items should not be reopened as backend gaps:

- Public event detail projection, categories, media, venue, and organization summaries.
- Public product price options and availability.
- Buyer wallet endpoint (`GET /tickets`).
- Free-order fulfillment and ticket issuance.
- Buyer payment confirmation via `POST /payments/:payment_id/refresh`.
- Preview commercial seed coverage and promotion-code validation.

The payment-refresh path was also exercised live through Chapa test mode:
successful hosted checkout → `state: "ready"` → one wallet ticket with the
guest claim fields present. The signed public ticket URL returned `200`, and
the public ticket-view OTP request returned `201`. The final OTP verification
request was rate-limited by Cloudflare after repeated smoke calls; local
integration coverage verifies the complete claim flow.

The third report’s parking finding is not in the active backend queue. The
fulfillment service and backend contract exist; the reported failure is a seed
fixture missing parking access zones. Track it with the environment/seed owner
if parking is required in the shared preview fixture.

## Implementation rule for the next step

G-01 through G-03, G-04 through G-10, G-15, and G-20 through G-21 were implemented in small,
independently reviewable slices through the companion plan
`docs/superpowers/plans/2026-09-08-frontend-backend-gap-remediation-implementation.md`.
G-22 was implemented through
`docs/superpowers/plans/2026-09-10-guest-payment-refresh-claim-context-implementation.md`.
G-15 was implemented through
`docs/superpowers/plans/2026-09-10-repeat-ticket-purchases-g15-implementation.md`.
Before starting G-12 through G-19, make the
relevant product/provider decision and update this tracker with the chosen
contract. G-11 remains conditional/planned separately. G-22 is implemented
and verified locally and on the Render preview.
