# Ticket Wallet Answer-Edit Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a respondent open and revise their own registration answers from a wallet ticket without leaking answer values to other ticket holders.

**Architecture:** Extract the attendee correction deadline into one `Ticketing::Answers::CorrectionWindow` query object, used by both `Answers::Revise` and the read projection. Add an authenticated respondent-only registration-answers endpoint; the general ticket wallet returns only respondent-scoped registration/edit metadata, never answer values.

**Tech Stack:** Rails 8.1, ActiveRecord, Pundit, ActiveModel Serializers, Minitest integration/service tests, Postman Collection v2.1.

---

## File map

- Create `app/services/ticketing/answers/correction_window.rb` and `test/services/ticketing/answers/correction_window_test.rb`.
- Modify `app/services/ticketing/answers/revise.rb` and `test/services/ticketing/answers/revise_test.rb` to delegate the existing cutoff check without changing its boundary behavior.
- Modify `app/controllers/ticketing/tickets_controller.rb`, `app/controllers/orders/payment_refresh_controller.rb`, `app/services/orders/payment_refresh.rb`, and `app/serializers/ticketing/ticket_wallet_serializer.rb` to expose registration/edit context only when the current user is the registration respondent.
- Create `app/policies/ticketing/registration_answer_set_policy.rb` and `app/serializers/ticketing/editable_registration_answer_serializer.rb`.
- Modify `app/controllers/ticketing/registration_answers_controller.rb` and `config/routes.rb` to add `GET /registrations/:id/answers` without changing existing show/revise actions.
- Modify `test/integration/ticketing/tickets_test.rb`, `test/integration/ticketing/registration_answers_test.rb`, `test/integration/orders/payment_refresh_test.rb`, and `postman/Digis API_collection.json`.

## Task 1: Characterize and extract the correction window

**Files:** Create `test/services/ticketing/answers/correction_window_test.rb`; modify `app/services/ticketing/answers/revise.rb` and `test/services/ticketing/answers/revise_test.rb`.

- [x] **Step 1: Add failing window tests first** for selected dates, fixed multi-date offers, cancelled access dates, missing schedules, and exact cutoff equality. Preserve the strict `Time.current > cutoff` boundary and successful exact replay after cutoff.
- [x] **Step 2: Run the correction-window/revise tests** and confirm the new query object does not exist while current behavior is characterized.
- [x] **Step 3: Implement `Ticketing::Answers::CorrectionWindow.call(registration:)`** using one batched aggregate path that returns the cutoff or `nil`.
- [x] **Step 4: Make `Answers::Revise` use the shared cutoff** while retaining answer lock, respondent authorization, retention/erasure checks, idempotency, replay-before-window order, and audit behavior.
- [x] **Step 5: Run the correction-window/revise tests** with `N_PLUS_ONE=1`; exact boundary and replay tests pass.

## Task 2: Add respondent-only answer retrieval

**Files:** Create `app/policies/ticketing/registration_answer_set_policy.rb` and `app/serializers/ticketing/editable_registration_answer_serializer.rb`; modify `app/controllers/ticketing/registration_answers_controller.rb`, `config/routes.rb`, and `test/integration/ticketing/registration_answers_test.rb`.

- [x] **Step 1: Write failing HTTP tests** for respondent success, same 404 for a different user, no-store, effective revisions, and no ciphertext/retention/audit/expired-value leakage.
- [x] **Step 2: Run the answer integration tests** and confirm the registration answer-set route is absent before implementation.
- [x] **Step 3: Add `GET /registrations/:id/answers`.** The lookup is respondent-scoped and returns safe answer schema, current effective retained values, and editability metadata; existing show/revise actions remain unchanged.
- [x] **Step 4: Preload submissions, answers, questions, and revisions.** Ciphertext and retention internals stay out of output; the endpoint sets `Cache-Control: private, no-store`.
- [x] **Step 5: Run answer HTTP tests** with `N_PLUS_ONE=1`.

## Task 3: Add a safe wallet entry point

**Files:** Modify both wallet controllers, `app/services/orders/payment_refresh.rb`, `app/serializers/ticketing/ticket_wallet_serializer.rb`, and wallet/payment-refresh integration tests.

- [x] **Step 1: Write failing wallet tests** for respondent context, transfer exclusion, tickets without registrations, and payment-refresh responses containing a registration-linked ticket.
- [x] **Step 2: Pass the authenticated user into serializer options** on both wallet paths, preload ticket registrations, and batch correction cutoffs without loading wallet answer rows or entire schedules per ticket.
- [x] **Step 3: Add a respondent-gated `registration_answers` wallet object.** Wallet responses contain no answer values, question schemas, answer IDs, counts, or can-edit state; the lazy endpoint owns answer rows and editability.
- [x] **Step 4: Run ticket-wallet, payment-refresh, and answer integration/service tests** with `N_PLUS_ONE=1`.

## Task 4: Sync and verify the wallet API

**Files:** Modify `postman/Digis API_collection.json`; retain both wallet API response paths in regression coverage.

- [x] Add the authenticated `GET /registrations/:id/answers` request and a privacy-safe example response to Postman.
- [x] Run wallet, payment-refresh, registration-answer, correction-window, and revise suites with `N_PLUS_ONE=1`; targeted RuboCop, `bin/rails zeitwerk:check`, Postman JSON parsing, and `git diff --check` pass.
