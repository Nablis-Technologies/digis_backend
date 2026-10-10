# Organization and Event Staff Invitations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace organizer-facing UUID staff addition with secure phone-first organization and event invitations that grant access only after an authenticated invitee verifies the invited phone and accepts.

**Architecture:** Organizations and Events own separate invitation models, policies, commands, delivery jobs, and roster projections. A small Core contact value object normalizes a phone/email and creates a type- and scope-separated keyed digest; it never looks up or creates users. Acceptance resolves only the already-authenticated user whose verified phone matches the invitation. Event invitations carry an optional assignment expiry distinct from their claim expiry. Scanner pairing remains in Ticketing and is not merged into general staff invitations.

**Tech Stack:** Rails 8.1, Active Record/PostgreSQL, Pundit, Core idempotency/audit/outbox, injected delivery senders, Minitest, ActiveModelSerializers, Postman.

---

## Scope and implementation gates

- This is backend work only. Frontend UX/PWA work remains a separate deliverable against the API contract in this plan.
- Phase 1 accepts phone invitations only. Email remains disabled until a real email delivery adapter and verified-email account claim path are implemented.
- Core phone-verification commands exist, but the configured sender is preview-only and the Messaging preview adapter simulates transport. No production SMS provider is configured in the repository. Build the provider-neutral invitation sender boundary and truthful no-provider behavior; do not report SMS as sent. Production SMS delivery remains a release gate until a real provider is selected and wired.
- In private preview, the authorized create/resend response may return a one-time share URL for manual delivery. It is returned only once with `Cache-Control: no-store, private`; it is not available from later roster reads.
- Do not create shadow Core users. Invited people without accounts sign up through the canonical phone-verified flow before claiming.
- Do not create a new worktree, reset development/Render databases, stage, or commit. The implementer works in the user's current branch and leaves review/commit to the user.
- Create one table per migration. New invitation tables each get their own migration. Update `db/structure.sql` from migrations/test DB only.

## File map

| Unit | Files | Responsibility |
|---|---|---|
| Shared Core primitives | `app/values/core/invitation_contact.rb`, `test/values/core/invitation_contact_test.rb`, `app/services/core/invitation_throttle.rb`, `test/services/core/invitation_throttle_test.rb` | Normalize one explicit email-or-phone input and apply independently keyed actor/contact/source rate limits without resolving or creating users. |
| Organization invitation | `db/migrate/20261009090000_create_organizations_membership_invitations.rb`; `app/models/organizations/membership_invitation.rb`; `app/services/organizations/membership_invitations/create.rb`, `claim.rb`, `resend.rb`, `revoke.rb`, `expire.rb`, `roster.rb`; `app/jobs/organizations/expire_membership_invitations_job.rb`; `app/controllers/organizations/owner_membership_invitations_controller.rb`, `owner_team_rosters_controller.rb`; `app/policies/organizations/membership_invitation_policy.rb`, `owner_team_roster_policy.rb`; `app/serializers/organizations/membership_invitation_serializer.rb`, `owner_team_roster_serializer.rb` | Pending organization membership invitation lifecycle and claim-before-grant. |
| Event staff invitation | `db/migrate/20261009090001_create_events_staff_invitations.rb`; `app/models/events/staff_invitation.rb`; `app/services/events/staff_invitations/create.rb`, `claim.rb`, `resend.rb`, `revoke.rb`, `expire.rb`, `revoke_for_cancellation.rb`, `roster.rb`; `app/jobs/events/expire_staff_invitations_job.rb`; `app/controllers/events/staff_invitations_controller.rb`, `staff_rosters_controller.rb`; `app/policies/events/staff_invitation_policy.rb`, `staff_roster_policy.rb`; `app/serializers/events/staff_invitation_serializer.rb`, `staff_roster_serializer.rb`; `app/services/events/cancellation/initiate.rb` | Pending event-scoped staff invitation lifecycle and claim-before-assignment. |
| Delivery | `app/jobs/organizations/deliver_membership_invitation_job.rb`, `app/jobs/events/deliver_staff_invitation_job.rb`, `config/initializers/organizations_outbox_handlers.rb`, `config/initializers/events_outbox_handlers.rb`, `config/initializers/staff_invitation_delivery.rb`, and `app/services/links/branded_url.rb` | Durable ID/revision-only delivery, honest status, and no-store one-time claim link generation. Reuse the existing public URL boundary; do not add token query parameters. |
| API/docs/tests | `config/routes.rb`, `config/recurring.yml`, `config/initializers/filter_parameter_logging.rb`, `config/locales/organizations/membership.en.yml`, `config/locales/events/staff_assignment.en.yml`, `postman/Digis API_collection.json`, and focused model/service/job/integration tests | Retire direct UUID create paths, document claim contract, protect token parameters, expire invitations, and verify behavior end to end. |

The latest migration currently ends at `20261007090001`; the two planned filenames are therefore unique. Each migration creates only its named invitation table.

## Task 1: Add shared contact and abuse-throttling primitives

**Files:**
- Create: `app/values/core/invitation_contact.rb`
- Test: `test/values/core/invitation_contact_test.rb`
- Create: `app/services/core/invitation_throttle.rb`
- Test: `test/services/core/invitation_throttle_test.rb`
- Reference: `app/services/core/phone_identity/resolve_or_create.rb`

- [x] **Step 1: Write contact normalization tests.** Cover Ethiopian phone forms accepted by the existing identity contract (`0911…`, `+251911…`), phone canonicalization to E.164, email trim/downcase for Phase 2, invalid phone/email, missing input, and both email and phone supplied.
- [x] **Step 2: Run the focused test and confirm it fails.** The five tests failed before implementation because `Core::InvitationContact` was missing.

Run: `bin/rails test test/values/core/invitation_contact_test.rb`

Expected: failures because `Core::InvitationContact` does not yet exist.
- [x] **Step 3: Implement `Core::InvitationContact.parse(email: nil, phone: nil)`.** It accepts exactly one input and returns an immutable value with `type`, transient normalized value, and masked value. Its `digest_for(scope_type:, scope_id:)` namespaces the storage blind index by domain, parent ID, and channel; its `rate_limit_digest` is type-namespaced but not parent-scoped so one contact cannot evade limits by using multiple organizations/events. It delegates Ethiopian phone parsing to `Core::PhoneIdentity::ResolveOrCreate.normalize`, canonicalizes email without claiming it is verified, and never calls `Core::User.find`, `find_or_create_by`, or creates accounts.
- [x] **Step 4: Run the contact test and lint.** Five contact tests passed. Focused RuboCop passed with no offenses.

Run: `bin/rails test test/values/core/invitation_contact_test.rb`

Expected: PASS. Run RuboCop on `app/values/core/invitation_contact.rb` and `test/values/core/invitation_contact_test.rb`; expected: no offenses.

- [x] **Step 5: Write throttle tests.** Verify independent limits for actor ID, global contact rate-limit digest, and source IP; verify each dimension uses the existing `Core::AuthThrottle::LIMIT` and `WINDOW` values; verify raw phone/email/token values never appear in Rails.cache keys.
- [x] **Step 6: Implement `Core::InvitationThrottle.call(actor_id:, contact_digest:, token_digest: nil, ip_address:)`.** Use keyed digests for cache keys and enforce all three dimensions on create/resend/claim attempts. For a valid token, throttle by actor, invitation contact rate-limit digest, and request IP; for invalid tokens, throttle by actor, token digest, and IP. Return the existing typed 429 `rate_limited` business error without exposing the failing dimension.
- [x] **Step 7: Run both focused tests and lint.** Ten tests/110 assertions passed. Focused RuboCop passed with no offenses.

Run: `bin/rails test test/values/core/invitation_contact_test.rb test/services/core/invitation_throttle_test.rb`

Expected: PASS. Then run `bundle exec rubocop --cache false app/values/core/invitation_contact.rb app/services/core/invitation_throttle.rb test/values/core/invitation_contact_test.rb test/services/core/invitation_throttle_test.rb`; expected: no offenses.

## Task 2: Add organization invitation persistence and model

**Files:**
- Create: `db/migrate/20261009090000_create_organizations_membership_invitations.rb`
- Create: `app/models/organizations/membership_invitation.rb`
- Test: `test/models/organizations/membership_invitation_test.rb`
- Modify: `db/structure.sql` after migration/test DB setup

- [x] **Step 1: Write model/schema tests first.** Verify accepted contact types, invitation states, organization roles (`admin`, `staff` only), finite expiry, encrypted contact/token storage, safe masked destination, and database-backed uniqueness of one pending invite per organization/contact digest.
- [x] **Step 2: Run the model test and confirm failure.** The four tests failed because `Organizations::MembershipInvitation` did not exist.

Run: `bin/rails test test/models/organizations/membership_invitation_test.rb`

Expected: failure because the model/table are absent.
- [x] **Step 3: Create exactly one table in the migration.** Include UUIDv7 ID; organization, inviter, and optional accepted-user FKs; `contact_type`, encrypted `contact_ciphertext`, 64-character `contact_digest`; requested role; pending/accepted/revoked/expired status; encrypted `claim_token_ciphertext` plus `claim_token_digest`; delivery status/revision/attempt metadata; expires/accepted/revoked/expired timestamps; and create/claim idempotency digests. Add status, role, contact-type, delivery-state, digest-format, and timestamp constraints plus FK and lookup indexes.
- [x] **Step 4: Add the partial unique index.** Enforce one pending contact invitation per organization with a unique index on `(organization_id, contact_digest)` where `status = 'pending'`. The contact digest namespace includes `email` or `phone`, preventing cross-channel aliasing.
- [x] **Step 5: Implement the model.** Add Rails encryption, associations, validations, masked-contact accessor, safe Ransack allowlists, and auditable behavior. Never expose token/contact ciphertext/digest from serializers.
- [x] **Step 6: Migrate and verify.** The local test database migration and six model tests passed (37 assertions).

Run: `RAILS_ENV=test bin/rails db:migrate`

Expected: migration succeeds and creates only `organizations_membership_invitations`. Then run the model test; expected: PASS.

## Task 3: Add event staff invitation persistence and model

**Files:**
- Create: `db/migrate/20261009090001_create_events_staff_invitations.rb`
- Create: `app/models/events/staff_invitation.rb`
- Test: `test/models/events/staff_invitation_test.rb`
- Modify: `db/structure.sql` after migration/test DB setup

- [x] **Step 1: Write model/schema tests first.** Verify event scope, allowed general roles (`manager`, `staff`, `contractor`), explicit exclusion of scanner from the general invitation API, lifecycle/delivery constraints, encrypted capabilities, finite invitation expiry, optional future `assignment_expires_at`, and pending-contact uniqueness per event.
- [x] **Step 2: Run the model test and confirm failure.** The six tests failed because `Events::StaffInvitation` did not exist.

Run: `bin/rails test test/models/events/staff_invitation_test.rb`

Expected: failure because the model/table are absent.
- [x] **Step 3: Create one event invitation table.** Include UUIDv7 ID; event, inviter, and optional accepted-user FKs; contact, role, status, token, delivery, invitation expiry, optional `assignment_expires_at`, acceptance, revocation, and idempotency fields matching the organization model's security contract. Do not put the scanner device/session into this table.
- [x] **Step 4: Add its partial unique index.** Unique `(event_id, contact_digest)` where `status = 'pending'`; include the channel type in the digest namespace.
- [x] **Step 5: Implement model validations, encryption, safe accessors, and Ransack allowlists.**
- [x] **Step 6: Migrate and verify.** The local test database migration and six model tests passed (73 assertions).

Run: `RAILS_ENV=test bin/rails db:migrate && bin/rails test test/models/events/staff_invitation_test.rb`

Expected: migration succeeds and the focused tests pass.

## Task 4: Implement organization invitation commands

**Files:**
- Create: `app/services/organizations/membership_invitations/create.rb`
- Create: `app/services/organizations/membership_invitations/claim.rb`
- Create: `app/services/organizations/membership_invitations/resend.rb`
- Create: `app/services/organizations/membership_invitations/revoke.rb`
- Create: `app/services/organizations/membership_invitations/expire.rb`
- Create: `app/jobs/organizations/expire_membership_invitations_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/services/organizations/membership_invitations/create_test.rb`
- Test: `test/services/organizations/membership_invitations/claim_test.rb`
- Test: `test/services/organizations/membership_invitations/resend_test.rb`
- Test: `test/services/organizations/membership_invitations/revoke_test.rb`
- Test: `test/services/organizations/membership_invitations/expire_test.rb`
- Test: `test/jobs/organizations/expire_membership_invitations_job_test.rb`

- [x] **Step 1: Test create authorization and pending-only behavior.** Owner may invite admin/staff; admin may invite staff only; other roles and owner-role invitation fail. Assert create stores an invitation expiring exactly seven days after creation and creates neither a Core user nor membership. Assert email is rejected as disabled in Phase 1.
- [x] **Step 2: Test duplicate, idempotency, expiry cleanup, and audit behavior.** Same key/same payload replays; same key/changed payload conflicts; a different key for an existing pending contact returns a safe duplicate result; an overdue pending row is expired under lock before a replacement is created; competing creates yield one pending row.
- [x] **Step 3: Implement create using `Core::InvitationContact`, `Core::InvitationThrottle`, `Core::IdempotencyKey`, organization-scoped advisory/row locks, audit logs, and the pending partial-index backstop.** Consume actor/contact/IP throttle budgets before delivery side effects. Return one-time claim material only on this authorized no-store mutation response.
- [x] **Step 4: Test and implement claim.** Apply the actor/contact/IP throttle, then require a valid token in the request body, authenticated `current_user`, `verified_at`, and exact normalized-phone match. Wrong token, unverified phone, mismatched phone, expired/revoked invitation, stale parent, and changed-payload replay do not create membership. Same-key/same-token replay returns the prior accepted result without creating a second membership or audit transition. Successful acceptance creates exactly one active membership, marks the invitation accepted, clears encrypted token material, records acceptance/audit metadata, and never adds a global role. Also prove an invitation created by an owner remains valid after that creator is removed; another authorized owner/admin may still revoke it.
- [x] **Step 5: Test and implement resend/revoke.** Resend rotates token and delivery revision without extending the original expiry. Revoke blocks claim. Both require authorized parent managers and idempotency keys.
- [x] **Step 6: Test and implement bounded expiration.** Expire due pending invitations in batches, clear encrypted claim material, preserve audit evidence, and make create/claim enforce expiry synchronously even if the scheduled job has not run.
- [x] **Step 7: Schedule organization invite expiry.** Added `expire_organization_membership_invitations` to production `config/recurring.yml` every minute, matching the existing invitation cleanup cadence.
- [x] **Step 8: Run all organization invitation service/job tests.** 29 tests/172 assertions passed with no failures or errors; focused RuboCop reported no offenses.

Run: `bin/rails test test/services/organizations/membership_invitations test/jobs/organizations/expire_membership_invitations_job_test.rb`

Expected: all tests pass.

## Task 5: Implement event staff invitation commands

**Files:**
- Create: `app/services/events/staff_invitations/create.rb`
- Create: `app/services/events/staff_invitations/claim.rb`
- Create: `app/services/events/staff_invitations/resend.rb`
- Create: `app/services/events/staff_invitations/revoke.rb`
- Create: `app/services/events/staff_invitations/expire.rb`
- Create: `app/services/events/staff_invitations/revoke_for_cancellation.rb`
- Create: `app/jobs/events/expire_staff_invitations_job.rb`
- Modify: `config/recurring.yml`
- Modify: `app/services/events/cancellation/initiate.rb`
- Test: `test/services/events/staff_invitations/create_test.rb`
- Test: `test/services/events/staff_invitations/claim_test.rb`
- Test: `test/services/events/staff_invitations/resend_test.rb`
- Test: `test/services/events/staff_invitations/revoke_test.rb`
- Test: `test/services/events/staff_invitations/expire_test.rb`
- Test: `test/services/events/staff_invitations/revoke_for_cancellation_test.rb`
- Modify: `test/services/events/cancellation/initiate_test.rb`
- Test: `test/jobs/events/expire_staff_invitations_job_test.rb`
- Remove after confirming no callers remain: `app/services/events/staff_assignments/assign.rb`, `test/services/events/staff_assignments/assign_test.rb`

- [x] **Step 1: Test role-grant authority.** Organization owner/admin or platform admin may invite roles permitted by `Events::AuthorizationResolver`; event manager may invite staff only. General invitation rejects scanner role; scanner remains on `/events/:event_id/scanner_invitations`.
- [x] **Step 2: Test pending-only create, duplicate, idempotency, scope, and expiry rules.** Assert create expires exactly seven days after creation, accepts a future optional `assignment_expires_at` independently of claim expiry, rejects a past assignment expiry, creates no active `EventStaffAssignment` before claim, and the invitation cannot cross event boundaries.
- [x] **Step 3: Implement create, resend, and revoke using `Core::InvitationContact`, `Core::InvitationThrottle`, `Core::IdempotencyKey`, event locks, audit/outbox patterns, and the pending partial-index backstop.** Consume independent actor/contact/IP throttle budgets before queuing delivery.
- [x] **Step 4: Test claim contact/auth behavior.** Apply the actor/contact/IP throttle and require an authenticated user with verified phone matching the invitation destination. On success, atomically create an active `EventStaffAssignment` for the invitee and event organization, copy `assignment_expires_at` to the assignment's `expires_at`, mark the invitation accepted, and audit inviter/claimant/scope/role. Same-key/same-token replay returns the accepted result without creating another assignment or audit transition. Do not add an organization membership or global role. Enforce one active general role (manager/staff/contractor) per event/user; scanner remains a separate coexisting assignment. A different-role invitation claim conflicts and must use the authorized change-role action.
- [x] **Step 5: Test the approved parent-owned rule.** Remove/suspend the creator's manager assignment after invitation creation; the valid event-owned invitation remains claimable until explicit revoke, expiry, event cancellation, or invalid parent state.
- [x] **Step 6: Test and implement bounded expiration.** Expire due invitations in batches; claim/create enforce current expiry and event state synchronously.
- [x] **Step 7: Revoke pending staff invitations when an event is cancelled.** Add `Events::StaffInvitations::RevokeForCancellation` to the event cancellation transaction in `app/services/events/cancellation/initiate.rb`; audit each transition without logging contact or token data. Test cancellation replay and already-accepted invitations.
- [x] **Step 8: Schedule event invite expiry.** Add `expire_staff_invitations` to production `config/recurring.yml` every minute, matching the existing invitation cleanup cadence.
- [x] **Step 9: Remove direct `Events::StaffAssignments::Assign` only after verifying its sole application caller is the retiring direct-create controller.** Keep `AssignFromDelegatedGrant`, which the scanner pairing flow uses.
- [x] **Step 10: Run event invitation and staff-assignment tests.** Focused suite and full repo suite both pass; the full repo run completed 4,030 tests/19,037 assertions with 0 failures/errors and 5 skips.

Run: `bin/rails test test/services/events/staff_invitations test/services/events/staff_assignments test/jobs/events/expire_staff_invitations_job_test.rb`

Expected: all retained event staff lifecycle tests and new invitation tests pass; the retired direct-Assign test file is gone.

## Task 6: Add durable invitation delivery and claim links

**Files:**
- Create: `app/jobs/organizations/deliver_membership_invitation_job.rb`
- Create: `app/jobs/events/deliver_staff_invitation_job.rb`
- Create: `config/initializers/organizations_outbox_handlers.rb`, `config/initializers/staff_invitation_delivery.rb`
- Modify: `config/initializers/events_outbox_handlers.rb`, `app/services/links/branded_url.rb`
- Test: `test/jobs/organizations/deliver_membership_invitation_job_test.rb`, `test/jobs/events/deliver_staff_invitation_job_test.rb`, `test/jobs/organizations/membership_invitation_delivery_outbox_test.rb`, `test/jobs/events/staff_invitation_delivery_outbox_test.rb`

- [x] **Step 1: Test jobs using injected sender doubles.** Verify jobs take only invitation ID/revision, re-check invitation status/revision/expiry, decrypt contact/token only at delivery boundary, pass stable provider idempotency key, record queued/accepted/delivered/failed/unknown truthfully, and retry provider failures without resurrecting revoked/accepted invitations.
- [x] **Step 2: Test no-provider behavior.** With no configured sender, status is unknown/unavailable—not sent/delivered—and the organizer's create/resend response still has the authorized one-time copy/share URL.
- [x] **Step 3: Implement domain jobs and outbox dispatch.** Keep organization/event delivery ownership local to each domain; do not introduce a Core-to-Messaging or Events-to-Ticketing dependency. Persist raw token encrypted for async delivery, pass only ID/revision through outbox/job arguments, and clear ciphertext after terminal lifecycle transitions.
- [x] **Step 4: Add `Links::BrandedUrl.membership_invitation` and `Links::BrandedUrl.staff_invitation`.** Generate paths `/organizations/membership-invitations/claim#token=...` and `/events/staff-invitations/claim#token=...` from `PUBLIC_APP_URL`; place the capability in the URL fragment, never a query/path. Add `Cache-Control: no-store, private` to create/resend responses and never include raw token in logs, audit, job args, or serializers.
- [x] **Step 5: Add provider integration as an explicit deployment gate.** The application adapter may use the existing provider-neutral injection boundary, but do not claim Phase 1 automatic SMS works until a real SMS adapter/provider is selected and configured. Test the preview adapter only as a simulation.
- [x] **Step 6: Run delivery and outbox tests.** Delivery and outbox tests pass in the focused and full repository runs.

Run: `bin/rails test test/jobs/organizations/deliver_membership_invitation_job_test.rb test/jobs/events/deliver_staff_invitation_job_test.rb`

Expected: all delivery outcomes and stale-revision cases pass without logging message content or tokens.

## Task 7: Expose invitation APIs and retire UUID create routes

**Files:**
- Create: `app/controllers/organizations/owner_membership_invitations_controller.rb`
- Create: `app/policies/organizations/membership_invitation_policy.rb`
- Create: `app/serializers/organizations/membership_invitation_serializer.rb`
- Create: `app/controllers/events/staff_invitations_controller.rb`
- Create: `app/policies/events/staff_invitation_policy.rb`
- Create: `app/serializers/events/staff_invitation_serializer.rb`
- Modify: `config/routes.rb`
- Modify: `app/controllers/events/event_staff_assignments_controller.rb`
- Modify: `config/locales/organizations/membership.en.yml`
- Modify: `config/locales/events/staff_assignment.en.yml`
- Modify: `config/initializers/filter_parameter_logging.rb`
- Test: `test/integration/organizations/membership_invitations_test.rb`, `test/integration/events/staff_invitations_test.rb`

- [x] **Step 1: Write integration tests for authentication, authorization, missing Idempotency-Key, invalid contact/role, successful create, response privacy, resend, revoke, claim, and rate-limit responses.** Assert claim token appears only in no-store create/resend material and is filtered from Rails request logs.
- [x] **Step 2: Implement domain-scoped management controllers and policies.** Permit one `phone` field in Phase 1; return a typed channel-not-enabled error for email. Never permit user_id, role status, inviter, accepted user, digest, ciphertext, or token from ordinary create fields.
- [x] **Step 3: Add exact claim actions.** `POST /organizations/membership_invitations/claim` and `POST /events/staff_invitations/claim` require Bearer auth, an Idempotency-Key, and `{ "token": "..." }` in JSON body. Ensure `:token` remains filtered and no route puts it in path/query.
- [x] **Step 3a: Add authenticated invitation previews.** `POST /organizations/membership_invitations/preview` and `POST /events/staff_invitations/preview` accept `{ "token": "..." }` in the body, require the authenticated account's verified phone to match, return only scope/inviter/role/expiry context, set `Cache-Control: no-store, private`, and do not mutate or accept the invitation. No Idempotency-Key is required because this is a read-only preview; token/IP/actor throttles still apply.
- [x] **Step 4: Replace UUID-based organizer mutations.** Remove `create` from nested owner memberships and event staff assignments routes; keep membership management and assignment list/show/suspend/revoke/activate/change-role. Retire generic event-assignment `PATCH`: it accepted `user_id`, which would rebind access by UUID without invitation claim, and all legitimate mutable lifecycle fields already have dedicated actions. Retire physical assignment `DELETE` too; `POST revoke` records the lifecycle transition and emits scanner-access revocation evidence. Do not remove `Core::MembershipManagement` create behavior globally—it is also included by `Admin::MembershipsController`.
- [x] **Step 5: Remove the direct-create action/service/test for event Assign after Task 5 verifies no other caller.** Keep `AssignFromDelegatedGrant` for scanner pairing.
- [x] **Step 6: Run the two integration tests and route audit.** New API integration tests pass; `bin/rails routes` confirms invite and roster routes and absence of owner/event assignment create/update/delete routes.

Run: `bin/rails test test/integration/organizations/membership_invitations_test.rb test/integration/events/staff_invitations_test.rb`

Expected: both domain flows pass; old organizer UUID create routes return no route/are absent, while admin membership administration and scanner invitations still route correctly.

## Task 8: Add composite organization and event staff rosters

**Files:**
- Create: `app/controllers/organizations/owner_team_rosters_controller.rb`
- Create: `app/services/organizations/membership_invitations/roster.rb`
- Create: `app/policies/organizations/owner_team_roster_policy.rb`
- Create: `app/serializers/organizations/owner_team_roster_serializer.rb`
- Create: `app/controllers/events/staff_rosters_controller.rb`
- Create: `app/services/events/staff_invitations/roster.rb`
- Create: `app/policies/events/staff_roster_policy.rb`
- Create: `app/serializers/events/staff_roster_serializer.rb`
- Modify: `config/routes.rb`
- Test: `test/integration/organizations/owner_team_rosters_test.rb`, `test/integration/events/staff_rosters_test.rb`

- [x] **Step 1: Write response-contract tests.** Organization roster returns separate memberships (active/suspended) and pending invitations collections, each with independent pagination. Event roster returns separate non-scanner assignments (active/suspended) and pending staff invitations collections with independent pagination. Invitation projections expose only masked destinations and no claim material/ciphertext/digests; active member/assignment fields stay within existing serializer and policy allowlists.
- [x] **Step 2: Implement domain-scoped read projections.** Use the existing Pundit organization/event scope, bounded queries, explicit serializer allowlists, and separate collection pagination. Scanner assignments/invitations remain exclusively in `GET /events/:event_id/scanners`.
- [x] **Step 3: Run roster tests with N+1 detection.** Both roster integrations passed with `N_PLUS_ONE=1`.

Run: `N_PLUS_ONE=1 bin/rails test test/integration/organizations/owner_team_rosters_test.rb test/integration/events/staff_rosters_test.rb`

Expected: all tests pass with no strict-loading/N+1 errors.

## Task 9: Synchronize API documentation and regression coverage

**Files:**
- Modify: `postman/Digis API_collection.json`
- Modify: `config/locales/organizations/membership.en.yml`
- Modify: `config/locales/events/staff_assignment.en.yml`
- Modify: `test/integration/organizations/owner_memberships_test.rb`, `test/integration/events/event_staff_assignments_test.rb`
- Add: `test/values/core/invitation_contact_test.rb`
- Add: `test/models/organizations/membership_invitation_test.rb`, `test/models/events/staff_invitation_test.rb`
- Add: `test/services/organizations/membership_invitations/`, `test/services/events/staff_invitations/`
- Add: `test/jobs/organizations/expire_membership_invitations_job_test.rb`, `test/jobs/events/expire_staff_invitations_job_test.rb`
- Add: `test/jobs/organizations/deliver_membership_invitation_job_test.rb`, `test/jobs/events/deliver_staff_invitation_job_test.rb`
- Add: `test/jobs/organizations/membership_invitation_delivery_outbox_test.rb`, `test/jobs/events/staff_invitation_delivery_outbox_test.rb`
- Add: `test/services/events/staff_invitations/revoke_for_cancellation_test.rb`
- Add: `test/integration/organizations/membership_invitations_test.rb`, `test/integration/events/staff_invitations_test.rb`
- Add: `test/integration/organizations/owner_team_rosters_test.rb`, `test/integration/events/staff_rosters_test.rb`

- [x] **Step 1: Update Postman.** Added create/list/resend/revoke/preview/claim and team/staff-roster requests with phone Phase 1 payloads, Bearer token, and Idempotency-Key; removed organizer UUID create/update/delete examples while preserving Admin membership and scanner invitation examples. JSON parses successfully.
- [x] **Step 2: Update old integration expectations.** Replaced direct owner/event UUID add tests with route-retirement assertions; retained membership/assignment list, role change, suspend, activate, and revoke tests.
- [x] **Step 3: Add security/concurrency cases.** Covered wrong/unverified contact, private preview before acceptance, expired/revoked token, replay/changed payload, concurrent claim exactly-one grant, unique pending-contact race, unauthorized role grant, parent cancellation, inviter-removal durability, one active general role, and scanner/general-role coexistence.
- [x] **Step 4: Run focused regression suites.** `N_PLUS_ONE=1` focused matrix passed: 177 tests, 1,134 assertions, 0 failures/errors/skips.

Run: `N_PLUS_ONE=1 bin/rails test test/values/core/invitation_contact_test.rb test/services/core/invitation_throttle_test.rb test/models/organizations/membership_invitation_test.rb test/models/events/staff_invitation_test.rb test/services/organizations/membership_invitations test/services/events/staff_invitations test/integration/organizations/owner_memberships_test.rb test/integration/organizations/membership_invitations_test.rb test/integration/organizations/owner_team_rosters_test.rb test/integration/events/event_staff_assignments_test.rb test/integration/events/staff_invitations_test.rb test/integration/events/staff_rosters_test.rb test/services/core/phone_verification_test.rb test/services/core/phone_identity/resolve_or_create_test.rb test/integration/ticketing/scanner_invitations_test.rb test/integration/ticketing/scanner_pairing_test.rb test/jobs/organizations/membership_invitation_delivery_outbox_test.rb test/jobs/events/staff_invitation_delivery_outbox_test.rb`

Expected: all focused tests pass with N+1 detection enabled.

- [x] **Step 5: Run repository checks.** Focused RuboCop, Zeitwerk, `git diff --check`, Postman JSON parse, and the complete Rails suite passed. Full suite: 4,030 tests, 19,037 assertions, 0 failures/errors, 5 skips.

    bundle exec rubocop --cache false app/values/core/invitation_contact.rb app/services/core/invitation_throttle.rb app/models/organizations/membership_invitation.rb app/models/events/staff_invitation.rb app/services/organizations/membership_invitations app/services/events/staff_invitations app/jobs/organizations/expire_membership_invitations_job.rb app/jobs/events/expire_staff_invitations_job.rb app/jobs/organizations/deliver_membership_invitation_job.rb app/jobs/events/deliver_staff_invitation_job.rb app/controllers/organizations/owner_membership_invitations_controller.rb app/controllers/organizations/owner_team_rosters_controller.rb app/controllers/events/staff_invitations_controller.rb app/controllers/events/staff_rosters_controller.rb app/policies/organizations/membership_invitation_policy.rb app/policies/organizations/owner_team_roster_policy.rb app/policies/events/staff_invitation_policy.rb app/policies/events/staff_roster_policy.rb app/serializers/organizations/membership_invitation_serializer.rb app/serializers/organizations/owner_team_roster_serializer.rb app/serializers/events/staff_invitation_serializer.rb app/serializers/events/staff_roster_serializer.rb app/services/events/cancellation/initiate.rb app/services/links/branded_url.rb config/initializers/organizations_outbox_handlers.rb config/initializers/events_outbox_handlers.rb config/initializers/staff_invitation_delivery.rb test/values/core/invitation_contact_test.rb test/services/core/invitation_throttle_test.rb test/models/organizations/membership_invitation_test.rb test/models/events/staff_invitation_test.rb test/services/organizations/membership_invitations test/services/events/staff_invitations test/integration/organizations/membership_invitations_test.rb test/integration/organizations/owner_team_rosters_test.rb test/integration/events/staff_invitations_test.rb test/integration/events/staff_rosters_test.rb test/jobs/organizations/expire_membership_invitations_job_test.rb test/jobs/events/expire_staff_invitations_job_test.rb test/jobs/organizations/deliver_membership_invitation_job_test.rb test/jobs/events/deliver_staff_invitation_job_test.rb

    bin/rails zeitwerk:check
    git diff --check
    ruby -rjson -e 'JSON.parse(File.read("postman/Digis API_collection.json"))'

  Then run the focused regression command in Step 4 and expected: no RuboCop offenses, Zeitwerk reports all good, Postman JSON parses, and the test commands complete with zero failures/errors.
- [ ] **Step 6: Confirm delivery readiness separately.** Not run in this branch: private preview deployment was not requested. Local integration tests cover create → preview → verified-phone claim → roster update. Automatic SMS remains unconfigured and is not production-ready until a real provider is selected and successfully sends/reports delivery.

## Release gates

- Phone-only API and manual claim-link fallback can be tested in preview without a production provider, but that does not prove SMS delivery.
- Selecting/configuring a real SMS provider and validating delivery receipts is required before declaring automated Phase 1 invitations production-ready.
- Email remains explicitly disabled until a verified-email identity path and real email adapter are delivered.
- Frontend implementation, link handling, and UI/UX verification are separate work after the backend contract is reviewed.
- Review and stage/commit decisions remain with the user; this plan does not authorize database resets or deployment.
