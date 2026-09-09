# Ticket Transfer Recipient Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver secure ticket-transfer links and support OTP acceptance by existing and shadow recipients.

**Architecture:** Keep ownership and credential transitions in `Ticketing::Transfers`. Store the raw delivery token encrypted on the transfer, while outbox events and jobs carry only durable IDs. Reuse the Links resolver and Messaging provider registry for branded URLs and preview/real channel delivery.

**Tech Stack:** Rails 8.1, Active Record encryption, Active Job/Solid Queue, Minitest, existing `Links`, `Core::PhoneVerification`, and `Messaging::Providers` boundaries.

---

### Task 1: Persist secure transfer delivery material

**Files:**
- Modify: `db/migrate/20260812090010_create_ticketing_ticket_transfers.rb`
- Modify: `app/models/ticketing/ticket_transfer.rb`
- Test: `test/models/ticketing/ticket_transfer_test.rb`

- [x] Add encrypted `token_ciphertext` with a required database column and accessor `token` while retaining the digest lookup field.
- [x] Ensure serializers, ransack fields, and audit metadata never expose the raw token.
- [x] Add model coverage for encrypted storage and required lifecycle fields.

### Task 2: Add branded transfer targets

**Files:**
- Modify: `db/migrate/20260717210202_create_links_short_links.rb`
- Modify: `app/models/links/short_link.rb`
- Modify: `app/services/links/target_resolver.rb`
- Modify: `app/services/links/branded_url.rb`
- Modify: `config/routes.rb`
- Test: `test/services/links/branded_url_test.rb`
- Test: `test/services/links/resolve_test.rb`

- [x] Allow `ticket_transfer` in the original link constraint and model allowlist.
- [x] Resolve transfer targets to the tokenized public transfer route.
- [x] Create compact `x-` canonical links and direct signed fallbacks.
- [x] Cover enabled/disabled links, collisions, and resolver privacy.

### Task 3: Deliver initiated transfers

**Files:**
- Modify: `app/services/ticketing/transfers/initiate.rb`
- Create: `app/jobs/ticketing/ticket_transfer_delivery_job.rb`
- Modify: `config/initializers/ticketing_outbox_handlers.rb`
- Modify: `app/services/messaging/providers/adapter.rb`
- Modify: `app/services/messaging/providers/preview_adapter.rb`
- Test: `test/jobs/ticketing/ticket_transfer_delivery_job_test.rb`
- Test: `test/services/ticketing/transfers/initiate_test.rb`

- [x] Persist the encrypted token and publish only transfer/ticket IDs.
- [x] Register `ticketing.ticket_transfer.initiated` to enqueue one transfer-delivery job.
- [x] Deliver SMS and optional email with idempotency keys; use preview logging in Render.
- [x] Keep provider failures retryable and leave transfer ownership unchanged.

### Task 4: Public landing and transfer-bound OTP

**Files:**
- Create: `app/controllers/ticketing/public_ticket_transfers_controller.rb`
- Create: `app/serializers/ticketing/public_ticket_transfer_serializer.rb`
- Modify: `config/routes.rb`
- Create: `test/integration/ticketing/public_ticket_transfers_test.rb`

- [x] Add public show and request-OTP routes with guest throttling and no-store headers.
- [x] Validate transfer token/status/expiry and return masked recipient plus event/ticket display data.
- [x] Create a `ticket_transfer` OTP challenge bound to the resolved recipient.
- [x] Return typed errors for invalid, expired, canceled, or already accepted transfers.

### Task 5: OTP acceptance for shadow recipients

**Files:**
- Create: `app/services/ticketing/transfers/accept_guest.rb`
- Modify: `app/controllers/ticketing/public_ticket_transfers_controller.rb`
- Modify: `config/locales/ticketing/package_workflow.en.yml`
- Test: `test/services/ticketing/transfers/accept_guest_test.rb`
- Extend: `test/integration/ticketing/public_ticket_transfers_test.rb`

- [x] Verify the short-lived OTP proof belongs to the transfer recipient and phone.
- [x] Lock transfer/ticket and atomically change owner plus replace the credential generation.
- [x] Return a signed ticket view for passwordless recipients; when password fields are supplied, set password, mark verified, and return JWTs.
- [x] Make accepted replay idempotent and reject conflicting/wrong proofs.

### Task 6: Gates and deployment handoff

**Files:**
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

- [x] Add public transfer routes, request bodies, and safe examples to Postman.
- [x] Run focused transfer/link/messaging tests with `N_PLUS_ONE=1`, then full `bundle exec rails test`.
- [x] Run RuboCop, Zeitwerk, Brakeman, and `git diff --check`.
- [x] Leave changes unstaged/uncommitted for review; Render auto-deploy follows the user’s push.
