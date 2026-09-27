# Frontend–Backend Gap Tracker

Date: 2026-09-26
Backend baseline checked: `331e2f7` (`HEAD` and `origin/feat/launch-hardening-telemetry`)
Status: G-01 through G-10, G-15, G-20 through G-22, G-27, G-29, and G-34 implemented locally; G-15 and G-22 have prior Render-preview verification; G-03's Chapa V2 destination model is implemented but usable payout rails/dispatch are not verified; G-27/G-29/G-34 Render preview verification is pending; G-23 through G-26 and G-28 remain open; G-11 and G-12 through G-19 remain decision/partial items as detailed below

## Purpose

This document consolidates the earlier frontend integration reports:

- `BACKEND_GAPS (1).md`
- `BACKEND_GAPS (2).md`
- `BACKEND_GAPS (3).md`

The reports were compared with the current Rails routes, controllers, policies,
serializers, services, seeds, tests, and the deployed preview behavior. The
September 21 `BACKEND_GAPS (4).md` snapshot was cross-checked against baseline
`331e2f7`; its proposed fixes are treated as claims, and product decisions stay
out of the confirmed implementation queue.

Only unequivocally true backend gaps are in the active queue below. Partial,
conditional, frontend-only, stale, and informational findings are intentionally
deferred to a later decision pass.

## Active true backend gaps

| ID | Verdict | Priority | Gap | Current evidence | Why it matters | Next implementation outcome | State |
|---|---|---|---|---|---|---|---|
| G-01 | True — blocking | P0 | Paid registrations remain `pending_payment` after payment acceptance | `AcceptPayment`/`FulfillOrder` fulfill the order and issue from the order item, but no paid-registration transition writes `confirmed` | The registration remains active and can block later purchases; registration and order state disagree | Transition the linked paid registration to `confirmed` atomically with accepted payment/fulfillment, with idempotent audit evidence | Implemented — verified locally |
| G-02 | True — blocking | P0 | No buyer release/cancel path for abandoned pending registrations | `ReleaseCheckout` and `RestartCheckout` close/release orders but do not cancel the associated registration | A buyer who abandons a checkout can remain blocked by the active registration identity slot | Add a buyer-scoped, idempotent release command for eligible `pending_payment` registrations; release holds and preserve terminal evidence | Implemented — verified locally |
| G-03 | Implemented with provider-rail follow-up | P0 | Marketplace seller payout destination registration was unsupported by Chapa | Seller accounts now persist encrypted Chapa destination details with a keyed digest and dispatch through the shared Finance transfer client; the supported destination list/type mismatch is tracked separately in G-26 | Registration code exists, but a created destination is not evidence that its provider rail can receive a payout | Keep destination encryption, verification/manual review, ledger, reserve, idempotency, and reconciliation gates; resolve G-26 and prove each supported rail with a test dispatch | Chapa V2 destination model implemented locally; usable payout rail and live dispatch remain unverified |
| G-04 | True — blocking | P0 | Signup has no server-side password/phone validation | `Core::UserAuthenticatable` uses `has_secure_password validations: false`; no password length/confirmation or phone-format validation is present | Client-side validation can be bypassed; malformed or weak accounts enter the system | Add model-level password length/confirmation and canonical Ethiopian phone validation with typed field errors | Implemented — verified locally |
| G-05 | True — blocking | P0 | Authentication endpoints have no brute-force throttling | No `rack-attack` or equivalent auth throttle exists in middleware/config | Unlimited login attempts weaken the otherwise sound token/authentication posture | Add atomic per-IP and per-identifier limits for login, signup, and refresh; return localized `429 rate_limited` responses | Implemented — verified locally |
| G-06 | True — blocking for accurate discovery pricing | P1 | Public event `price_from_minor` includes non-ticket extras | `Events::Public::EventListSerializer#price_from_minor` previously computed the minimum across every active event product instead of ticket products only | Discovery cards and price filters showed an amount that could be the price of an add-on rather than the cheapest ticket | Restrict the projection to active ticket products and add a regression fixture containing a cheaper non-ticket product | Implemented — verified 2026-09-09 |
| G-07 | True — degrading | P1 | Public products omit non-sensitive `requires_ticket` | `Catalog::Public::EventProductSerializer` exposes the dedicated boolean from product metadata | Frontend can present ticket-required add-ons accurately; server enforcement semantics remain a product decision tracked in G-31 | Keep the narrow boolean projection; do not expose all organizer metadata | Implemented — verified locally; enforcement decision deferred |
| G-08 | True — blocking for dynamic forms | P1 | No public registration schema for dynamic form questions/scopes | Public consent requirements exist, but registration-form questions, versions, response scopes, and validation rules are organizer-only | Frontend cannot render arbitrary event forms or correctly submit slot-coordinate answers | Add a public, event/ticket-type-scoped schema projection with published-version and privacy boundaries | Implemented — verified locally |
| G-09 | True — degrading | P1 | Resale browse has no reliable “my listings” discovery | `GET /resale_listings` returns the public shape and filters to active rows; seller identity is intentionally omitted | Sellers cannot rediscover their own active listings across devices or sessions | Add an owner filter or a seller-safe projection for the caller’s own rows without leaking seller identity to buyers | Implemented — verified locally |
| G-10 | True — degrading | P1 | Wallet ticket projection omits resale policy fields | `TicketWalletSerializer#ticket_type` now exposes resale eligibility, cap configuration, cutoff, and max-resale fields; the calculated percentage ceiling is still absent (G-28) | The frontend can show resale eligibility and policy, but cannot show the seller the exact percentage-based maximum before submit | Keep policy fields owner-only and expose the resolved cap through G-28; backend remains authoritative | Policy fields implemented — verified locally; G-28 open |
| G-15 | True — product requirement confirmed | P1 | Confirmed registrations incorrectly block repeat purchases | The registration uniqueness boundary and `Submit` lookup now exclude `confirmed`; the rebuilt Render preview accepts a second confirmed registration for the same buyer and ticket type | Buyers can start another purchase while the existing purchase-limit lock remains authoritative for cumulative capacity | Keep one blocking pending registration per product/date, allow new registrations after confirmation, and enforce the cumulative cap through the locked purchase-limit allocations | Implemented — verified locally and on Render preview 2026-09-10 |
| G-20 | True — degrading | P1 | Wallet tickets omit purchased non-ticket extras | `Ticketing::TicketWalletSerializer` now projects fulfilled order add-ons without payment/provider fields | Buyers can see extras purchased with a ticket after checkout | Owner-only `add_ons` projection is eager-loaded on both `GET /tickets` and payment refresh | Implemented — verified 2026-09-09 |
| G-21 | True — degrading | P1 | RSVP events have no submission endpoint | Public free RSVP reuses registrations and tickets with guest OTP or authenticated submission; audience proof and its lifecycle are implemented under G-27, and capacity/waitlist contract decisions remain deferred (G-30) | Public RSVP happy path exists, but explicit full/waitlist behavior remains outside the original implementation | Keep the shared registration, capacity, confirmation, and QR issuance boundaries; decide G-30 before promising gated/waitlist UX | Basic endpoint implemented — verified 2026-09-09; G-27 locally verified 2026-09-26 |
| G-22 | True — product requirement confirmed | P1 | Guest payment refresh lacked claim context for starting OTP/account claiming without the SMS link | Guest refresh now uses a guest-only ticket serializer that returns `registration_id`, signed `ticket_view_token`, direct `ticket_view_url`, and branded-or-fallback `short_url`; authenticated wallet refresh remains unchanged | The confirmation screen can open the signed public ticket view, request OTP, and submit the existing guest claim flow without depending on SMS delivery | Implemented — local + Render preview verified 2026-09-10 (view/OTP request passed; final claim check was Cloudflare-rate-limited) |
| G-23 | True — payment security blocker | P0 | Chapa webhook verification accepts signatures that do not authenticate the raw request body | At baseline `331e2f7`, `ChapaClient#webhook_signature_candidates` accepts `HMAC-SHA256("", raw_body)` and body-independent candidates; a 2026-09-21 test webhook matched `OLD_SELF_HMAC`, while documented raw-body HMAC did not. The handler returned 200 and payment processing ran through this fallback | Anyone can calculate the empty-key candidate without the webhook secret; a forged provider-success event could reach fulfillment if it matches a payment | Verify only the configured webhook secret over exact raw bytes with constant-time comparison; remove self-HMAC, empty-key, API-key, canonicalized-body, and digest fallbacks; stop logging full signature values; verify payment state/amount/currency/reference before fulfillment as required by the provider contract | Open — code verified 2026-09-25; provider still emitted legacy self-HMAC in last live evidence 2026-09-21. Recheck after Chapa confirms a fix |
| G-24 | True — blocking | P0 | One elapsed settlement-grace payment can fail the checkout-expiry sweep | `Orders::ExpireCheckout#move_to_grace!` raises when `settlement_grace_expires_at <= now`; `call` converts that exception into a failed sweep. A live sweep failure was reported with active checkouts remaining on 2026-09-15 | Stale `pending_payment` orders can continue blocking later checkout attempts, and one problematic candidate can prevent processing later candidates | Reconcile the elapsed payment using the settlement-grace provider check and release only when safe; isolate failures per candidate so one order cannot abort the full sweep; preserve retryable/auditable failure state | Open — source verified 2026-09-25; prior live reproduction reported 2026-09-15 |
| G-25 | True — degrading | P1 | Checkout does not reject an event date that has already passed | `Orders::BuildQuote#normalize_item_request` checks product/event association and date selection, while reservation checks the product sales window and that dates belong to the event; neither rejects past/completed/cancelled event dates | A still-published event can remain quotable and payable after its event date | At quote/order creation, require an eligible future event date and reject explicitly selected past/completed/cancelled dates; preserve multi-date events that still have future dates | Open — source verified 2026-09-25; live past-event purchase was reported in the September 21 assessment |
| G-26 | True — blocking for seller payout setup | P1 | Seller payout destinations have no authoritative bank/rail discovery contract | `SellerPayoutAccountsController` has no bank-list action; `SellerPayoutAccount::TYPES` only allows `bank`. The September 18 provider probe in the gap report returned a `store_value` rail, which does not match that model type. `VerifyPayoutAccount` skips slug validation when the provider list is `nil` | The frontend can offer rails the backend rejects, while an unavailable bank-list response can let unsupported slugs through; creating an account does not prove it can receive a payout | Expose an authenticated seller-safe list of currently supported payout destinations; align accepted types and database constraints with explicitly supported dispatch mappings; fail closed if provider discovery is unavailable; verify a test payout before marking a rail supported | Open — source verified 2026-09-25; provider-list evidence reported 2026-09-18; payout dispatch for the `store_value` rail remains unverified |
| G-27 | True — blocking for audience-gated RSVP | P1 | Public RSVP did not forward and consume audience authorization proof | `PublicRsvpsController` accepts `access_code`/`invitation_token` on OTP and submit; registration validates proof, consumes access-code quantity under the code lock or claims a pending invitation, enforces invitation allowance, and persists the selected foreign key. Exact/active replays resolve before consumption; later registration failures roll mutations back. G-34 returns proof at terminal release/rejection/expiry and reacquires on reconsideration. Checkout release coordinates through Orders, keeping payment-state knowledge out of Ticketing; resale success/expiry/fulfillment use a deadlock-safe TicketType→checkout-key order | Gated free RSVP previously failed; simply validating a proof left max-use codes reusable and invitations pending | Keep proof validation, usage/allowance enforcement, invitation claim, registration linkage, and registration persistence in one transaction; exact replays must not consume/claim twice | G-27/G-34 implemented and locally verified 2026-09-26; affected cross-flow suite and N+1: 193 tests/1,452 assertions each; resale expiry/fulfillment concurrency regression passed 5 consecutive repeats; RuboCop clean on 65 changed Ruby files; Zeitwerk, Postman JSON, route-preservation, module-boundary, and diff checks passed. Render preview not verified |
| G-28 | True — degrading | P1 | Wallet resale policy omits the amount needed to calculate a percentage cap | `TicketWalletSerializer#ticket_type` exposes `resale_percentage_cap_bps` but not the acquisition value or server-calculated cap; `Marketplace::CalculatePriceCap` owns that calculation | Sellers cannot determine the allowed asking-price ceiling before submitting a listing | Add a safe server-calculated `resale_price_cap_minor` projection (preferred) or the minimum required acquisition basis; keep cap calculation authoritative in Marketplace | Open — source verified 2026-09-25; live 422/201 evidence reported 2026-09-18 |

## Explicitly deferred to the next decision pass

These findings are not being treated as unequivocal implementation tasks yet:

| ID | Classification | Reason deferred |
|---|---|---|
| G-11 | Decision recorded | Guest/shadow checkout selected with immediate ticket issuance after payment. OTP/password claiming happens later; signed public ticket views expire at event end + 30 days. The first implementation slice is deployed and verified on the Render preview; live SMS-provider configuration and production smoke evidence remain pending. Transfer recipient delivery and shadow-recipient OTP acceptance are implemented in `docs/superpowers/plans/2026-09-09-ticket-transfer-recipient-delivery-implementation.md`. Unified phone-first dashboard auth and OAuth are intentionally separated into `docs/superpowers/plans/2026-09-08-unified-auth-oauth-implementation.md`. |
| G-12 | Partial | The frontend/backend `cbe` mismatch is real, but the correct fix may be frontend mapping to a provider-supported canonical method rather than adding `cbe` to shared backend enums. |
| G-13 | Partial | Public `event_setting.config` is intentionally allowlisted to two keys. The September assessment also reports inert/unwritable event-level `event_type`, access, and RSVP fields. Decide which settings are real product contracts and expose a curated public projection; do not copy all frontend-consumed keys into the whitelist. |
| G-14 | Conditional | The current auth API still drops `name` and has no self-service profile update. Make these active only if the product requires name persistence/profile editing; the September assessment says signup now sends a name. |
| G-16 | Stale/partial | Generic consumer notifications/preferences, seller payout routes, and quote-time promotions now exist. Seller destination creation is implemented under G-03; missing bank/rail discovery and provider-type mismatch are tracked in G-26. |
| G-17 | Informational | Reserved slugs/history are future hardening, not a current integration blocker. |
| G-18 | Migration resolved; integration blocker tracked separately | Chapa API V2 migration is implemented. The webhook signature contract remains open under G-23; the V2 migration must not be described as complete end-to-end until standard raw-body signature verification works without compatibility fallbacks. |
| G-19 | Partial | Audience authorization exists outside public RSVP, and frontend proof wiring remains. G-27 now forwards and consumes/claims access-code/invitation proof through public RSVP and is verified locally; preview verification is pending. |
| G-30 | Product decision | RSVP inventory capacity exists, but the public RSVP contract has no dedicated sold-out response, public waitlist join, or invite-request path, and event-level `rsvp_capacity` is inert. Decide capacity display, waitlist enrollment, and invite-request behavior before adding endpoints; related to G-13/G-21. |
| G-31 | Product decision | `requires_ticket` is exposed on public products but is not enforced at quote/order time. Define whether it means “must be purchased with a ticket” or is only a presentation hint before adding an order gate; related to G-07. |
| G-32 | Conditional / informational | Public event payloads omit participants/lineup and venue media/coordinates. Add only if those are confirmed public product surfaces; do not block current checkout/discovery on them. |
| G-33 | Security-sensitive follow-up | Guest payment refresh validates the guest quote token before reconciliation. Do not remove that proof check for accepted payments until a durable guest-ownership credential is defined; the September assessment reports frontend mitigation and a token/order mismatch scenario. Related to G-22. |

## Already resolved or superseded

The following report items should not be reopened as backend gaps:

- G-29 decision: reuse the same pending registration across sequential checkout
  restarts. The order-item uniqueness boundary is now `(registration_id,
  order_id)`, preserving one item per registration per order and closed-order
  evidence while allowing a replacement order. New orders still require a
  `pending_payment` registration; buyer/event checkout locking prevents two
  active orders from using it. Verified locally in the 193-test cross-flow set
  (1,452 assertions, including N+1 detection).
- G-34: access-code uses and invitations are restored on buyer release,
  organizer rejection, or final checkout expiry; reconsideration revalidates
  and reacquires the proof before approval. Invitation claimant binding is
  preserved. Verified locally in the 193-test cross-flow set (1,452 assertions,
  including N+1 detection); Render preview verification remains pending.

- Public event detail projection, categories, media, venue, and organization summaries.
- Public product price options and availability.
- Buyer wallet endpoint (`GET /tickets`).
- Free-order fulfillment and ticket issuance.
- Buyer payment confirmation via `POST /payments/:payment_id/refresh`.
- Preview commercial seed coverage and promotion-code validation.

The payment-refresh/guest-claim path was exercised through Chapa test mode on
2026-09-10: hosted checkout → `state: "ready"` → wallet ticket with guest claim
fields; the signed public ticket URL returned `200`, and ticket-view OTP request
returned `201`. That flow evidence predates the September 21 webhook signature
audit and does not prove secure provider authentication. See G-23. The final OTP
verification request was rate-limited by Cloudflare after repeated smoke calls;
local integration coverage verifies the complete claim flow.

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
Before starting G-12 through G-19 or G-30 through G-33, make the relevant
product/provider decision and update this tracker with the chosen contract.
G-11 remains conditional/planned separately. G-22 is implemented and was
verified locally and on the Render preview. G-27, G-29, and G-34 are implemented
and locally verified; Render preview verification for these latest changes is
pending. G-23 through G-26 and G-28 remain open, with G-23 the immediate
payment-security priority.
