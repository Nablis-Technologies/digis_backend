# G-27 Live Render Preview E2E Verification Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute a live end-to-end verification of G-27 (Audience Proof / Gated Admissions in Composable Admission Selections) on the Render preview environment (`https://digis-backend-preview.onrender.com`), covering access code and invitation token lifecycles, failure modes, atomic consumption, replay idempotency, and secret redaction.

**Tech Stack:** Rails 8.1, Ruby 3.4, Render Preview (`srv-da1plmflk1mc73a30vu0`), Composable Admission Selections API.

---

### Task 1: Access Code Live Verification (Rejection, Creation, Consumption & Replay)

**Target:** `cancellation-drill-event` (disposable drill event, simple no-form event)
- Event ID: `01a09d6b-65ac-7e54-bd6f-bf7e9c87a249`
- Product ID: `01a09d6b-686e-74c1-a71a-a453d6faed05` (`Cancellation Drill General Admission`)
- Ticket Type ID: `01a09d6b-6906-7526-a27f-95a373751991`

- [x] **Step 1: Update ticket type audience to `access_code`**
  Sent `PATCH /events/01a09d6b-65ac-7e54-bd6f-bf7e9c87a249/event_products/01a09d6b-686e-74c1-a71a-a453d6faed05/ticket_type` with `audience: "access_code"`.
  Verified HTTP 200 OK returning `audience: "access_code"`.

- [x] **Step 2: Generate unique access code via Organizer API**
  Generated access code `DRILL-VIP-74ABC4` (`max_uses: 2`, `active: true`) via `POST /events/:event_id/event_products/:product_id/ticket_type/access_codes`.
  Verified HTTP 201 Created and recorded code ID `01a0f19f-b98a-7705-aa50-705d97f2eec2`.

- [x] **Step 3: Test rejection when proof is missing**
  Submitted `POST /public/events/cancellation-drill-event/admission_selections` without `audience_proof`.
  Asserted: HTTP 422 Unprocessable Entity.

- [x] **Step 4: Test rejection when proof is invalid**
  Submitted with `audience_proof: { access_code: "NONEXISTENT-CODE" }`.
  Asserted: HTTP 422 Unprocessable Entity.

- [x] **Step 5: Test successful admission selection with valid access code**
  Submitted with `audience_proof: { access_code: "DRILL-VIP-74ABC4" }`.
  Asserted: HTTP 201 Created, order `01a0f1a0-1694-7f4e-a160-c903f36c6526` created (`next_action: checkout_required`).
  Verified secret scrubbing: plaintext code and code digest redacted from response.

- [x] **Step 6: Verify atomic usage count increment**
  Fetched access codes via Organizer GET. Asserted `used_count: 1`.

- [x] **Step 7: Test exact idempotent replay**
  Replayed identical request with same `Idempotency-Key`.
  Asserted: HTTP 201 Created returning identical order `01a0f1a0-1694-7f4e-a160-c903f36c6526`.
  Asserted: `used_count` remained 1 (no double consumption).

- [x] **Step 8: Revert ticket type audience back to `public`**
  Sent `PATCH .../ticket_type` with `audience: "public"`. Verified HTTP 200 OK.

---

### Task 2: Invitation Token Live Verification (Redemption, Claim, & Secret Scrubbing)

**Target:** `addis-music-fest-2026` (`Fest VIP Pass`)
- Event ID: `01a09d6b-320d-7815-a985-baf3e2300106`
- Product ID: `01a09d6b-513c-73bb-82e7-3b06cdf060e0` (`Fest VIP Pass`, `audience: "code_or_invitation"`)
- Ticket Type ID: `01a09d6b-5196-75f0-bdf6-04a65ff6a481`

- [x] **Step 1: Generate unique invitation token via Organizer API**
  Created invitation via `POST .../ticket_type/invitations` for attendee `+251911000009`.
  Verified HTTP 201 Created and recorded plaintext token.

- [x] **Step 2: Test rejection with invalid invitation token**
  Submitted `POST /public/events/addis-music-fest-2026/admission_selections` with `audience_proof: { invitation_token: "bogus-invitation-token-12345" }`.
  Asserted: HTTP 422 Unprocessable Entity.

- [x] **Step 3: Test successful admission selection with valid invitation token**
  Submitted with valid `invitation_token`, form answers, and legal consents.
  Asserted: HTTP 201 Created (`registration.status: "pending_approval"`, `next_action.type: "awaiting_approval"`).
  Asserted: Plaintext token is redacted from response payload.

- [x] **Step 4: Verify invitation claim status update**
  Fetched invitations via Organizer GET.
  Asserted: Invitation status transitioned to `accepted` (`accepted_at: 2026-09-30T09:23:38.032Z`).

---

### Task 3: Consolidate Results & Update Tracker

- [x] **Step 1: Update Gap Tracker `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`**
  Updated G-27 status from "Live gated-proof submission remains unverified" to "Resolved & verified live on Render preview".
- [x] **Step 2: Commit and push tracking updates**
- [x] **Step 3: Provide complete verification report with all proofs**
