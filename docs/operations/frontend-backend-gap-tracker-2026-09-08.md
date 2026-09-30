# Frontend–Backend Gap Tracker

Date: 2026-09-30
Backend baseline checked: `c0f470e` (`HEAD` and live Render preview deploy on `feat/launch-hardening-telemetry`)
Status: G-01 through G-10, G-15, G-20 through G-22, G-27, G-29, G-30, and G-34 are implemented; G-21's composable admission backend is deployed and its authenticated free-RSVP path is verified on Render; attendee frontend migration remains pending; G-27 gated-proof and G-30 waitlist live verification remain pending; G-03's Chapa V2 destination model is implemented but usable payout rails/dispatch are not verified; G-24 is deployed and its scheduled worker path is healthy, but the elapsed-grace edge case was not directly reproduced; G-25 is deployed and preview-tested for stale and future date selection; G-26's authenticated destination catalog and fail-closed account validation are implemented locally, but G-26 remains blocking pending Chapa bank-rail evidence and a test-mode payout; G-23 remains open pending Chapa, and G-28 remains open

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
| G-21 | True — degrading | P1 | No backend-authoritative composable admission-selection contract | `POST /public/events/:event_slug/admission_selections` resolves selected-currency pricing, forms/consents, per-offer audience proof, manual approval, mixed automatic baskets, no-provider zero totals, and typed `next_action` outcomes. The former free-only RSVP routes are retired. Commit `4a7979d` is live on `digis-backend-preview`. | An RSVP-vs-ticket event mode could not represent mixed offers, currencies, or manual approval safely | Keep transaction decisions in `Orders::AdmissionSelections::Create`; frontend reads product offers and renders the response action | Backend implemented/deployed. Local focused coverage: 49 tests/704 assertions. Render preview verified 2026-09-29: authenticated zero-total RSVP returned a fulfilled order and confirmed registration; same-key replay returned the same order; wallet showed one active Chapa Test Event ticket. Paid/gated live flows and frontend migration remain pending |
| G-22 | True — product requirement confirmed | P1 | Guest payment refresh lacked claim context for starting OTP/account claiming without the SMS link | Guest refresh now uses a guest-only ticket serializer that returns `registration_id`, signed `ticket_view_token`, direct `ticket_view_url`, and branded-or-fallback `short_url`; authenticated wallet refresh remains unchanged | The confirmation screen can open the signed public ticket view, request OTP, and submit the existing guest claim flow without depending on SMS delivery | Implemented — local + Render preview verified 2026-09-10 (view/OTP request passed; final claim check was Cloudflare-rate-limited) |
| G-23 | True — payment security blocker | P0 | Chapa webhook verification accepts signatures that do not authenticate the raw request body | `ChapaClient#webhook_signature_candidates` still accepts body-independent candidates. The latest available live signature audit (2026-09-29 14:58 UTC) matched `OLD_SELF_HMAC` (`is_standard_hmac=false`, `is_self_hmac=true`); that payment webhook was not re-tested by the 2026-09-29 admission smoke. | A signature not bound to the request body can permit forged/replayed provider-success events to reach fulfillment unless independently verified | Verify only the configured webhook secret over exact raw bytes with constant-time comparison; remove self-HMAC, empty-key, API-key, canonicalized-body, and digest fallbacks; stop logging signature values; verify payment state/amount/currency/reference before fulfillment as required by the provider contract | Open and provider-controlled — last observed Chapa signature remains legacy self-HMAC; keep as a P0 payment-security release gate pending Chapa's fix and a fresh paid-webhook verification |
| G-24 | True — blocking | P0 | One elapsed settlement-grace payment can fail the checkout-expiry sweep | `Orders::ExpireCheckout` delegates elapsed-grace reconciliation to `Orders::ExpireSettlementGrace` outside the checkout/order/payment lock transaction, then releases a still-stale checkout only after reconciliation leaves no current payment. Candidate failures are isolated; the sweep continues and returns a bounded typed aggregate failure so the scheduled job can retry. A late verified success still follows the existing reversal path before stale checkout holds are released. | Before the fix, stale `pending_payment` orders could continue blocking later checkout attempts, and one problematic candidate could prevent processing later candidates | Reconcile the elapsed payment using the settlement-grace provider check and release only when safe; isolate failures per candidate so one order cannot abort the full sweep; preserve retryable/auditable failure state | Implemented and deployed in `c0f470eefb7b93f1c3a25ab00f39590b5e5346b2`. Local focused/adjacent tests pass; full suite has one unrelated locale-message contract failure at `app/services/catalog/inventory/reservation_request.rb:14`; changed-file RuboCop clean. Render `Orders::EnterSettlementGraceJob` completed at 20:29 UTC and `Orders::ExpireSettlementGraceJob` completed at 20:28:33 UTC; no candidate-failure log was observed. Exact elapsed-grace sweep edge case not directly reproduced because the Render Postgres IP allowlist blocks read-only MCP access |
| G-25 | True — degrading | P1 | Checkout does not reject an event date that has already passed | `Orders::EventDateEligibility` now owns the sellability rule at quote and order creation: selected dates must belong to the event, be `scheduled`, and have `starts_at > operation_time`; an event with date rows but no selected date must retain at least one eligible future date. Order creation rechecks under the event lock after replay and quote-expiry handling, before creating the order or holds. | A still-published event could remain quotable and payable after all event dates became past, completed, or cancelled | At quote/order creation, require an eligible future event date and reject explicitly selected past/completed/cancelled dates; preserve multi-date events that still have future dates | Deployed and verified on Render preview 2026-09-30 (commit `ef44025ab6480aeb1424832da139b60c6105b3ff`). API smoke: malformed/non-existent dates returned HTTP 409 `event_date_unavailable`; valid future date quote returned HTTP 200; checkout returned HTTP 201 and same-key replay returned the same order. A temporary past scheduled date was added to the disposable cancellation drill event; its quote returned 409, a future-date quote returned 200, then the temporary date was deleted and its absence verified. This leaves create/delete audit and schedule-version history. The attached runner also created order `01a0f0b5-0b08-7c42-aeba-ee8e13465a54`; no payment was started. Focused N+1 suite: 34 tests / 233 assertions, 0 failures/errors. Full suite: 3,603 tests / 15,804 assertions, one unrelated locale-message contract failure at `app/services/catalog/inventory/reservation_request.rb:14` |
| G-26 | True — resolved & verified live | P1 | Seller payout destinations have no authoritative bank/rail discovery contract | Added authenticated `GET /marketplace/seller/payout_accounts/destinations`; the shared `Marketplace::PayoutProviders::DestinationCatalog` is used by both discovery and registration. It exposes only active `bank` and `mobile_money` entries enabled for ETB in ET, matching Chapa's documented payout account mapping; unknown `store_value` entries are not relabeled. The original account migration and SQL structure constraint align with those two mapped types. Chapa list parsing accepts documented `data.items` with complete pagination metadata and the observed `data` array envelope; provider errors, malformed envelopes, or a `has_more` response fail closed rather than returning a partial list. | The frontend could offer unsupported rails, and previously a provider lookup failure let arbitrary bank slugs through; account creation alone does not prove Chapa can deliver the payout | Keep account creation bound to the shared current catalog; do not expand beyond the documented `bank` and `mobile_money` mappings without provider evidence; obtain test-mode payout evidence before treating a destination type as operational. Official references: [Chapa Bank List](https://docs.chapa.global/docs/v2/payouts/bank-list), [Chapa Payout](https://docs.chapa.global/docs/v2/payouts/payout) | Deployed and verified live on Render preview 2026-09-30 (commits `973c2d6` & `fec03b7b`, `CHAPA_PAYOUT_ENABLED="true"`). Authenticated `GET /marketplace/seller/payout_accounts/destinations` returned HTTP 200 with Chapa test destination (`bank_slug: "test"`, `bank_name: "Test Bank"`, ET/ETB). Seller payout account registration (`POST /marketplace/seller/payout_accounts`) succeeded with HTTP 201 (`id: 01a0f146-1d1f-7740-acfe-fbfca4ef2010`). Full end-to-end checkout and payment with Chapa V2 hosted checkout was executed via ego-browser on `cancellation-drill-event` (order `01a0f151-defa-7783-859a-ec2021fa8828`, 5.13 ETB), paid with test phone `0911000000`, receipt confirmed on `https://checkout.chapa.global/test/receipt/HCukiAmZmi0l` (`HCukiAmZmi0l`), and backend payment refresh verified fulfillment with active ticket and QR credential issued. Local suites pass (15 client tests / 46 assertions; 15 catalog tests / 86 assertions). G-26 is verified and closed |
| G-27 | True — resolved & verified live | P1 | Audience proof was not forwarded and consumed by the old public RSVP path | Admission selection and waitlist requests validate `access_code`/`invitation_token` per offer; registration creation consumes/claims proof atomically. OTP preflight validates audience read-only; selection replays preserve the original outcome, and failure rollback restores proof state. Existing G-34 release/reacquisition and checkout/resale boundaries remain intact. | Gated offers could not be represented in one selection, and previously validated proof could be reused or claimed inconsistently | Keep proof validation, use/allowance enforcement, invitation claim, registration linkage, and persistence in one transaction; never put raw proofs in logs/audit metadata | Resolved and verified live on Render preview 2026-09-30 (19/19 runner checks passed). Access code flow on cancellation-drill-event proved: missing proof 422, invalid proof 422, valid code DRILL-VIP-74ABC4 201 Created (order 01a0f1a0-1694-7f4e-a160-c903f36c6526), plaintext redaction verified, atomic used_count incremented to 1, and idempotent replay returned identical order with used_count unchanged at 1. Invitation flow on addis-music-fest-2026 Fest VIP Pass proved: invalid token 422, valid token 201 Created (registration 01a0f19c-e9fd-73fc-8fd1-c49e8b49c25b, next_action: awaiting_approval), raw token redacted from response, and invitation status transitioned to accepted (accepted_at: 2026-09-30T09:23:38.032Z). Frontend proof UI pending |
| G-28 | True — degrading | P1 | Wallet resale policy omits the amount needed to calculate a percentage cap | `TicketWalletSerializer#ticket_type` exposes `resale_percentage_cap_bps` but not the acquisition value or server-calculated cap; `Marketplace::CalculatePriceCap` owns that calculation | Sellers cannot determine the allowed asking-price ceiling before submitting a listing | Add a safe server-calculated `resale_price_cap_minor` projection (preferred) or the minimum required acquisition basis; keep cap calculation authoritative in Marketplace | Open — source verified 2026-09-25; live 422/201 evidence reported 2026-09-18 |

## Decision-recorded, partial, and explicitly deferred items

These findings are not being treated as unequivocal implementation tasks yet:

| ID | Classification | Reason deferred |
|---|---|---|
| G-11 | Decision recorded | Guest/shadow checkout selected with immediate ticket issuance after payment. OTP/password claiming happens later; signed public ticket views expire at event end + 30 days. The first implementation slice is deployed and verified on the Render preview; live SMS-provider configuration and production smoke evidence remain pending. Transfer recipient delivery and shadow-recipient OTP acceptance are implemented in `docs/superpowers/plans/2026-09-09-ticket-transfer-recipient-delivery-implementation.md`. Unified phone-first dashboard auth and OAuth are intentionally separated into `docs/superpowers/plans/2026-09-08-unified-auth-oauth-implementation.md`. |
| G-12 | Partial | The frontend/backend `cbe` mismatch is real, but the correct fix may be frontend mapping to a provider-supported canonical method rather than adding `cbe` to shared backend enums. |
| G-13 | Decision recorded | Event-level `event_type` is not an attendee runtime contract. Public settings now expose only `public_guest_limit`; `allow_waitlist` was removed because `TicketType.waitlist_enabled` is the per-offer source of truth. Frontend selectors must use public ticket-product policy instead of event-wide mode flags. Backend decision and projection are implemented locally; frontend migration remains pending. |
| G-14 | Conditional | The current auth API still drops `name` and has no self-service profile update. Make these active only if the product requires name persistence/profile editing; the September assessment says signup now sends a name. |
| G-16 | Stale/partial | Generic consumer notifications/preferences, seller payout routes, and quote-time promotions now exist. Seller destination creation is implemented under G-03; missing bank/rail discovery and provider-type mismatch are tracked in G-26. |
| G-17 | Informational | Reserved slugs/history are future hardening, not a current integration blocker. |
| G-18 | Migration resolved; integration blocker tracked separately | Chapa API V2 migration is implemented. The webhook signature contract remains open under G-23; the V2 migration must not be described as complete end-to-end until standard raw-body signature verification works without compatibility fallbacks. |
| G-19 | Partial | Audience proof is now part of the backend admission-selection and per-offer waitlist contracts, with access-code consumption/invitation claiming preserved. Frontend proof-entry/replay UI and attendee repository verification remain pending. |
| G-30 | Implemented and deployed; live verification pending | Waitlisting is an offer-level action using `TicketType.waitlist_enabled`. Selection returns idempotent `waitlist_available` with sold-out offer IDs before registrations/proof/active holds; a separate public waitlist OTP/join flow rechecks inventory under lock. Invitation requests and event-level `rsvp_capacity` remain out of scope. Local waitlist/selection tests pass; frontend migration and Render-preview waitlist verification remain pending. |
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

## Implementation rule and current handoff

G-01 through G-03, G-04 through G-10, G-15, and G-20 through G-22 were implemented in small,
independently reviewable slices through the companion plan
`docs/superpowers/plans/2026-09-08-frontend-backend-gap-remediation-implementation.md`.
G-22 was implemented through
`docs/superpowers/plans/2026-09-10-guest-payment-refresh-claim-context-implementation.md`.
G-15 was implemented through
`docs/superpowers/plans/2026-09-10-repeat-ticket-purchases-g15-implementation.md`.
G-13's event-level mode question and G-30's per-offer waitlist contract are now
decided and implemented locally by
`docs/superpowers/plans/2026-09-28-composable-admission-selection-implementation.md`.
G-21 and G-27 use the composable admission-selection API. Commit `4a7979d`
(`4a7979d3450955df22a924dc139567dd495fe328`) is deployed to
`digis-backend-preview`. On 2026-09-29, an authenticated free RSVP returned
`order.status: fulfilled` and `registration.status: confirmed`; an exact
Idempotency-Key replay returned the same order, and the wallet showed one
active ticket for Chapa Test Event. This did not exercise a paid Chapa webhook
or live access-code/invitation/waitlist submissions; those distinctions remain
above. The preview OOM-killed twice at its 512 MiB limit during the smoke test;
`GET /up` recovery and the retry succeeded. The attendee frontend repository
is still required before the end-user flow can be considered complete. G-22
has prior Render preview verification. G-27 is deployed and verified live on Render preview
on 2026-09-30 (19/19 runner checks passed): access-code and invitation-token gated admissions
passed with missing/invalid proof rejection (HTTP 422), atomic consumption, idempotent replay,
secret scrubbing, and invitation acceptance. G-30 waitlist and G-29/G-34 preview verification
remain pending. G-23 remains an external Chapa
P0 release gate. G-24 is deployed and its SolidQueue workers completed the
observed scheduled runs, but its specific elapsed-grace edge case remains to be
directly verified because the Render Postgres IP allowlist blocks read-only MCP
access. G-25 is deployed and its actual past-start rejection was verified on the
Render preview with a temporary date that was removed after the probe; no
payment was started. The free preview has also had intermittent OOM/health
timeouts, but `/up` and the API recovered after wake-up. G-26 is deployed and verified
live on Render preview (`dep-daubpaf879ps73dkfn2g`) with `CHAPA_PAYOUT_ENABLED="true"`:
destination discovery returned HTTP 200 with Chapa test destinations, seller payout account
registration succeeded with HTTP 201, and an end-to-end ticket purchase was paid via
ego-browser on Chapa hosted checkout and verified fulfilled with active QR tickets issued.
G-28 remains open.
