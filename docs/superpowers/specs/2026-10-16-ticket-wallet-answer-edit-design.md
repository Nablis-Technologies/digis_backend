# Ticket Wallet Answer-Edit Context Design

## Goal

Let an authenticated attendee reopen and correct their own registration answers from a wallet ticket, while keeping answer values out of general ticket projections and enforcing exactly the same edit deadline on reads and writes.

## Proposed API and authorization

- The wallet projection may include a small `registration_answers` context only when the signed-in user is the registration respondent: registration ID, answer collection URL, and `answers_editable_until`. A ticket holder who is not the respondent receives no registration-answer context. The wallet does not preload answer rows just to decide button visibility; the lazy endpoint reports whether any answers remain editable.
- Add authenticated `GET /registrations/:id/answers`. It is scoped to `Registration.user_id == current_user.id`; another user receives the same not-found behavior as an unknown registration. The response contains the current effective, retained answer values, safe question labels/types/options/validation rules, response coordinates, and editability metadata. It never includes ciphertext, retention policy internals, audit values, or organizer-only fields.
- The answer response shape is `{ registration_id, answers_editable_until, can_edit_answers, answers }`. Each answer row contains its ID, question key/label/type/options/validation rules, response scope and slot coordinates, effective retained `value` when available, and an `editable` boolean. Erased/expired values are omitted; an empty or wholly non-editable set reports `can_edit_answers: false`.
- Keep the existing `POST /registration_answers/:id/revise` command and `Idempotency-Key` contract unchanged.
- Extract the attendee correction cutoff into one shared `Ticketing::Answers::CorrectionWindow` query object. The revise command remains authoritative and uses this same object; the read projection cannot drift from write enforcement.
- Erased or retention-expired answer values are not returned. `can_edit_answers` is false when the correction window is closed or no answer can be revised.

## Alternatives considered

1. Embed all answer values in `GET /tickets`. Rejected: it repeats potentially sensitive data on every wallet refresh and risks exposing a respondent's answers to a ticket holder after transfer.
2. Return a respondent-only registration link/deadline in the wallet and load answers through an authenticated registration subresource. Recommended: minimal wallet payload, explicit ownership authorization, lazy loading, and one shared edit-window rule.
3. Add answer-edit fields directly to ticket credentials. Rejected because registration answers belong to the registration/respondent, not to a transferable credential.

## Verification

Cover respondent success, other-user and transferred-holder denial, expired/erased answer handling, deadline equality/boundaries, original answer plus effective revision projection, idempotent revise behavior, private cache headers, strict loading, and N+1 behavior. Run focused answer, ticket-wallet, and integration suites with `N_PLUS_ONE=1`, targeted RuboCop, route checks, and Postman JSON validation.
