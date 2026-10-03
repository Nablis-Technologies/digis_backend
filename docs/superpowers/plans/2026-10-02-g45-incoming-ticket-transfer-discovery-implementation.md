# G-45 Incoming Ticket Transfer Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a verified authenticated transfer recipient discover an incoming ticket transfer in their notification inbox and accept it by transfer ID without a bearer token.

**Architecture:** Extend the existing transactional notification registry to project the already-committed `ticketing.ticket_transfer.initiated` outbox event into a recipient-owned, in-app-only notification. Add an ID-scoped acceptance mode to the existing locked `Ticketing::Transfers::Accept` service; retain token-based acceptance, guest OTP acceptance, and the existing SMS/email delivery job.

**Tech Stack:** Rails 8, ActiveRecord, transactional outbox, Messaging notifications, Minitest, Postman collection JSON, RuboCop.

---

**Execution status:** Implemented and verified locally on 2026-10-03; not deployed; changes remain uncommitted.

## File map

- Modify `app/services/messaging/notification_types.rb`: allow a type-specific channel list and define the safe, recipient-owned `transfer_incoming` projection.
- Modify `app/services/messaging/outbox_handlers/publish_transactional_notification.rb`: map the initiated event and load its transfer/ticket display associations.
- Modify `app/services/ticketing/transfers/accept.rb`: resolve either a bearer-token transfer or a transfer ID scoped to the actor, then share the same locked state machine.
- Modify `app/controllers/ticketing/transfers_controller.rb`: use ID acceptance when the authenticated recipient omits `token`; preserve token behavior when supplied.
- Modify `config/locales/messaging/notifications.en.yml`: add incoming-transfer notification copy.
- Modify `test/services/messaging/notification_types_test.rb`, `test/services/messaging/notification_projection_test.rb`, `test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb`, and `test/services/ticketing/transfers/accept_test.rb`: cover channels, allowlist, replay-safe notification, and ID-scoped accept.
- Modify `test/jobs/core/dispatch_outbox_event_job_test.rb`, `test/integration/ticketing/transfers_test.rb`, and `test/integration/messaging/notifications_test.rb`: verify recipient-only acceptance, full initiated-outbox dispatch, and inbox visibility/privacy end to end.
- Modify `postman/Digis API_collection.json`: document the in-app notification shape and tokenless authenticated accept request.
- Modify `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`: record backend implementation while leaving frontend integration/live verification separate.

## Task 1: Add failing notification contract tests

**Files:**
- Modify: `test/services/messaging/notification_types_test.rb`
- Modify: `test/services/messaging/notification_projection_test.rb`

- [x] **Step 1: Define expected incoming-transfer projection and channel contract**

Add a notification type test asserting `transfer_incoming` is `transactional`, belongs to `source.to_user`, deduplicates by transfer ID, and has exactly one channel:

```ruby
definition = Messaging::NotificationTypes.fetch("transfer_incoming")
assert_equal [ "in_app" ], definition.channels
```

Use a transfer-shaped source with ticket/event/product associations and assert the safe projection contains only `transfer_id`, `ticket_id`, `event_id`, `event_title`, `ticket_label`, and `expires_at`.

- [x] **Step 2: Prove sensitive values cannot be projected**

Add a projection test where the submitted data contains `token`, `token_digest`, `phone`, or `email` and assert `Messaging::NotificationProjection::UnsafeData` is raised. The accepted projection must be a flat hash of IDs, labels, and expiry only.

- [x] **Step 3: Run tests to verify the intended red state**

Run:

```bash
bin/rails test test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb
```

Expected: the new tests fail because `transfer_incoming` is not registered yet.

## Task 2: Implement the in-app notification definition

**Files:**
- Modify: `app/services/messaging/notification_types.rb`
- Modify: `config/locales/messaging/notifications.en.yml`

- [x] **Step 1: Allow each notification definition to select channels**

Add a keyword default to the registry helper and pass it to the immutable definition object, which already accepts and freezes a channel list:

```ruby
def definition(key:, category:, mandatory:, data_keys:, recipients:, dedupe:,
  projector: nil, channels: NotificationDelivery::CHANNELS)
  NotificationTypeDefinition.new(
    key:, category:, mandatory:, channels:, data_keys:,
    locale_scope: "messaging.notifications", recipient_resolver: recipients,
    dedupe_resolver: dedupe, projector:
  )
end
```

Existing notification types retain the current default channel set.

- [x] **Step 2: Register `transfer_incoming` with an in-app-only projection**

Add the definition in `app/services/messaging/notification_types.rb` with `channels: %w[in_app]`, recipient `source.to_user`, dedupe key `transfer-incoming:#{source.id}:v1`, and projection values sourced from the transfer, ticket, event, and event product. Do not include token ciphertext, token digest, sender/recipient contact details, or a URL.

- [x] **Step 3: Add the translated notification text**

Add `transfer_incoming.title` and `transfer_incoming.body` below the existing `transfer_received` copy in `config/locales/messaging/notifications.en.yml`.

- [x] **Step 4: Run the contract tests green**

Run:

```bash
bin/rails test test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb
```

Expected: type/channel/projection tests pass and every existing notification keeps its prior channels.

## Task 3: Project the existing initiated-transfer outbox event

**Files:**
- Modify: `app/services/messaging/outbox_handlers/publish_transactional_notification.rb`
- Modify: `test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb`

- [x] **Step 1: Add event mapping and eager source resolution**

Map `ticketing.ticket_transfer.initiated` to `transfer_incoming`. Resolve the transfer by the outbox payload's `transfer_id`, preloading recipient plus ticket's event and event product:

```ruby
when "ticketing.ticket_transfer.initiated"
  Ticketing::TicketTransfer.includes(:to_user, ticket: [ :event, :event_product ]).find(
    @event.payload.fetch("transfer_id")
  )
```

Do not modify the existing priority-100 SMS/email job handler in `config/initializers/ticketing_outbox_handlers.rb`.

- [x] **Step 2: Add outbox projection and replay tests**

Create a transfer through `Ticketing::Transfers::Initiate`, dispatch its committed outbox event twice, and assert exactly one recipient-owned `transfer_incoming` notification exists with one `in_app` delivery and no `sms` or `email` delivery. Assert notification data excludes bearer token, token digest, phone, and email.

- [x] **Step 3: Run the focused handler test**

Run:

```bash
bin/rails test test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb
```

Expected: all handler tests pass; replay creates no duplicate notification or delivery rows.

## Task 4: Add recipient-scoped ID acceptance to the existing state machine

**Files:**
- Modify: `app/services/ticketing/transfers/accept.rb`
- Modify: `app/controllers/ticketing/transfers_controller.rb`
- Modify: `test/services/ticketing/transfers/accept_test.rb`
- Modify: `test/integration/ticketing/transfers_test.rb`

- [x] **Step 1: Add failing service tests for ID resolution**

Add tests asserting a verified `@recipient` accepts a pending transfer using only `transfer_id`, and another user cannot resolve/accept that ID. The wrong-user result must not expose whether the transfer exists; assert the existing safe `transfer_invalid`/not-found contract selected for the scoped lookup.

- [x] **Step 2: Extend `Accept` to resolve exactly one credential mode**

Change initialization to accept `token: nil, transfer_id: nil, actor:`. In the existing transaction, resolve with a token digest when token is present; otherwise resolve by both transfer ID and `to_user_id: @actor.id`. The resolved row must enter the same `with_lock`, verified-recipient validation, expiry/status validation, generation check, cutoff check, ownership update, credential replacement, audit, and accepted-outbox path already used by token acceptance. Do not duplicate the acceptance transaction.

- [x] **Step 3: Branch the existing controller action without changing its route**

When `params[:token]` is present, keep the existing token-digest precheck and call signature. When absent, call the service with `transfer_id: params.require(:id)` and `actor: current_user`. Keep the existing required Idempotency-Key guard.

- [x] **Step 4: Run service and integration tests**

Run:

```bash
bin/rails test test/services/ticketing/transfers/accept_test.rb test/integration/ticketing/transfers_test.rb test/integration/ticketing/public_ticket_transfers_test.rb
```

Expected: token acceptance, guest OTP acceptance, and the new authenticated ID acceptance all pass; cross-user ID acceptance is not found/forbidden without state changes.

## Task 5: Verify recipient inbox visibility and document API contract

**Files:**
- Modify: `test/integration/messaging/notifications_test.rb`
- Modify: `postman/Digis API_collection.json`
- Modify: `docs/operations/frontend-backend-gap-tracker-2026-09-08.md`

- [x] **Step 1: Add inbox end-to-end assertions**

Create an initiated transfer, dispatch the outbox chain, then `GET /notifications` as the recipient. Assert the incoming notification is present, its safe data includes the transfer ID and expiry, no token/contact fields are serialized, and another user cannot see it.

- [x] **Step 2: Document tokenless acceptance and notification data**

Update the existing Postman `POST /ticket_transfers/{{transferId}}/accept` description and request example to show authenticated ID acceptance with an empty JSON body and required `Idempotency-Key`. Retain a separate example or description for token-based acceptance. Add a `transfer_incoming` notification response example containing only the six allowlisted safe fields.

- [x] **Step 3: Update G-45 with verified scope**

Record in the gap tracker that backend inbox projection and authenticated ID acceptance are implemented and locally verified. Keep frontend display, user-facing action wiring, and live deployment verification as separate pending evidence.

- [x] **Step 4: Validate Postman JSON**

Run:

```bash
ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json")); puts "Postman JSON OK"'
```

Expected output: `Postman JSON OK`.

## Task 6: Run the full focused regression and lint suite

**Files:** No additional files.

- [x] **Step 1: Run notification and transfer regression tests**

Run:

```bash
N_PLUS_ONE=1 bin/rails test test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb test/services/ticketing/transfers/accept_test.rb test/jobs/core/dispatch_outbox_event_job_test.rb test/integration/messaging/notifications_test.rb test/integration/ticketing/transfers_test.rb test/integration/ticketing/public_ticket_transfers_test.rb
```

Expected: all tests pass with no strict-loading/N+1 failures; existing SMS/email transfer delivery remains covered and unchanged.

- [x] **Step 2: Lint changed Ruby files**

Run:

```bash
bundle exec rubocop app/services/messaging/notification_types.rb app/services/messaging/outbox_handlers/publish_transactional_notification.rb app/services/ticketing/transfers/accept.rb app/controllers/ticketing/transfers_controller.rb test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb test/services/ticketing/transfers/accept_test.rb test/jobs/core/dispatch_outbox_event_job_test.rb test/integration/messaging/notifications_test.rb test/integration/ticketing/transfers_test.rb
```

Expected: no offenses in changed Ruby files.

- [x] **Step 3: Review privacy and change boundaries**

Run:

```bash
git diff --check -- app/services/messaging/notification_types.rb app/services/messaging/outbox_handlers/publish_transactional_notification.rb app/services/ticketing/transfers/accept.rb app/controllers/ticketing/transfers_controller.rb config/locales/messaging/notifications.en.yml test/services/messaging/notification_types_test.rb test/services/messaging/notification_projection_test.rb test/services/messaging/outbox_handlers/publish_transactional_notification_test.rb test/services/ticketing/transfers/accept_test.rb test/jobs/core/dispatch_outbox_event_job_test.rb test/integration/messaging/notifications_test.rb test/integration/ticketing/transfers_test.rb 'postman/Digis API_collection.json' docs/operations/frontend-backend-gap-tracker-2026-09-08.md
```

Expected: no whitespace errors, no schema changes, no bearer token in inbox data, and no duplicate SMS/email delivery path.
