# Registration Task 1 Review Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the seven verified Task 1 foundation defects without implementing the planned Task 6 retention purge.

**Architecture:** Keep application validation and PostgreSQL guards aligned. Edit the existing `90113` trigger migration and refresh `db/structure.sql`; do not add compatibility migrations. Use focused Minitest red/green cycles before the full verification suite.

**Tech Stack:** Ruby 3.x, Rails 8.1, Active Record, PostgreSQL, Minitest, Active Record Encryption, RuboCop, Brakeman.

---

### Task 1: Reject invalid option-key schemas

**Files:**
- Modify: `app/models/ticketing/registration_question.rb:155-167`
- Modify: `app/services/ticketing/forms/validate_submission.rb:228-236`
- Test: `test/models/ticketing/registration_foundation_test.rb`
- Test: `test/services/ticketing/forms/validate_submission_test.rb`

- [ ] **Step 1: Write failing tests**

Add a model test that builds a `multiple_choice` question with two identical `allowed_option_keys` and asserts `validation_rules` is invalid. Add a service test that passes the same malformed question hash to `ValidateSubmission` and asserts the result code is `invalid_validation_rules`.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
bin/rails test test/models/ticketing/registration_foundation_test.rb test/services/ticketing/forms/validate_submission_test.rb
```

Expected: the new duplicate-key assertions fail before the implementation.

- [ ] **Step 3: Implement the smallest shared invariant**

In `RegistrationQuestion#validate_option_key_rules`, reject an `allowed_option_keys` array unless all entries are valid strings, refer to declared option keys, and are unique. Keep the existing `ValidateSubmission#valid_allowed_options?` uniqueness check and ensure its boolean expression also rejects duplicate option keys in the normalized schema.

- [ ] **Step 4: Run the focused tests and confirm success**

Run the command from Step 2. Expected: all tests pass.

### Task 2: Make submission evidence and registration snapshots immutable

**Files:**
- Modify: `app/models/ticketing/registration_form_submission.rb:15-18`
- Modify: `app/models/ticketing/registration.rb:45-46,154-160`
- Modify: `db/migrate/20260727090113_add_registration_immutability_triggers.rb`
- Modify: `db/structure.sql`
- Modify: `test/models/ticketing/registration_foundation_test.rb`
- Modify: `test/services/ticketing/answers/revise_test.rb`

- [ ] **Step 1: Write failing model and SQL tests**

Extend `RegistrationFoundationTest` to create a published form submission, then assert that changing `submitted_at` is invalid and that `update_all(submitted_at: ...)` raises `ActiveRecord::StatementInvalid`. Extend the existing registration immutability test to change `package_quantity`, `admissions_per_unit_snapshot`, `party_size`, and `selected_event_date_id`, asserting model invalidity and SQL rejection.

Change the on-behalf correction setup in `ReviseTest` to create the submission with `submitted_by_user: core_users(:support)` from the start; the test must no longer mutate a submission after creation.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
bin/rails test test/models/ticketing/registration_foundation_test.rb test/services/ticketing/answers/revise_test.rb
```

Expected: the new immutability assertions fail, and the existing on-behalf test exposes the forbidden submission update.

- [ ] **Step 3: Add application guards**

Add a persisted-record validation to `RegistrationFormSubmission` that adds a base immutability error whenever any update is attempted. Expand `Registration#scope_immutable_after_submission` to reject changes to `event_id`, `ticket_type_id`, `selected_event_date_id`, `package_quantity`, `admissions_per_unit_snapshot`, and `party_size` after a submission exists.

- [ ] **Step 4: Add database guards**

In `90113`, add a `ticketing_registration_submission_immutable` trigger function that raises on every update or delete of `ticketing_registration_form_submissions`, bind it with a `BEFORE UPDATE OR DELETE` trigger, and remove it in `down`. Expand `ticketing_registration_same_event_guard` so its post-submission immutability condition includes the six registration scope/snapshot columns listed above.

- [ ] **Step 5: Refresh the schema and run the focused tests**

Apply the edited original migration to the current database, dump `db/structure.sql`, and run the command from Step 2. Expected: all focused tests pass.

### Task 3: Enforce retention policy ownership and monotonic activation

**Files:**
- Modify: `app/models/core/data_retention_policy.rb:55-65`
- Modify: `app/models/ticketing/registration_answer.rb:28-31,143-155`
- Modify: `db/migrate/20260727090113_add_registration_immutability_triggers.rb`
- Modify: `db/structure.sql`
- Modify: `test/models/core/data_retention_policy_test.rb`
- Modify: `test/models/ticketing/registration_answer_test.rb`
- Modify: `test/services/ticketing/answers/revise_test.rb`
- Modify: `test/services/ticketing/forms/persist_submission_test.rb`

- [ ] **Step 1: Write failing retention tests**

Add a policy test that creates version 1 as draft and version 2 as active, retires version 2, then asserts activating version 1 is invalid. Add answer tests for a draft policy, a wrong-category policy, and a future-effective policy; each must be rejected. Update existing answer/revision fixtures to use active policies with effective timestamps and the correct category (`registration_free_text` for text questions).

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
bin/rails test test/models/core/data_retention_policy_test.rb test/models/ticketing/registration_answer_test.rb test/services/ticketing/answers/revise_test.rb test/services/ticketing/forms/persist_submission_test.rb
```

Expected: the new policy and answer invariant tests fail before implementation.

- [ ] **Step 3: Implement model validation**

Change `DataRetentionPolicy#version_is_monotonic` so a persisted draft transitioning to `active` is compared with the maximum version in its category/jurisdiction, while `active -> retired` remains valid. Add `RegistrationAnswer#retention_policy_matches_question` that derives `registration_free_text` for `short_text`/`long_text` and `registration_structured` for all other allowed question types, then requires an active policy effective by `answered_at` with that category.

- [ ] **Step 4: Implement database validation**

Extend `core_retention_policy_immutable` to reject `draft -> active` when `NEW.version` is not greater than every other policy version in the same category/jurisdiction. Extend `ticketing_registration_answer_integrity_guard` to load policy category, status, and effective timestamp, derive the expected category from the question type, and raise unless the policy is active, effective by `answered_at`, and category-compatible.

- [ ] **Step 5: Refresh the schema and run the focused tests**

Apply the edited original migration, dump `db/structure.sql`, and rerun the command from Step 2. Expected: all focused tests pass.

### Task 4: Return typed errors for nil submissions and repair seeded forms

**Files:**
- Modify: `app/services/ticketing/forms/validate_submission.rb:13-27`
- Modify: `app/services/ticketing/forms/persist_submission.rb:8-31`
- Modify: `db/seeds/dev.rb:580-585`
- Test: `test/services/ticketing/forms/validate_submission_test.rb`
- Test: `test/services/ticketing/forms/persist_submission_test.rb`

- [ ] **Step 1: Write failing nil-input tests**

Call `ValidateSubmission` with `submission: nil` and a valid schema, and call `PersistSubmission` with `submission: nil`; assert both return failure results with code `invalid_submission`, not exceptions.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
bin/rails test test/services/ticketing/forms/validate_submission_test.rb test/services/ticketing/forms/persist_submission_test.rb
```

Expected: the new tests fail with `NoMethodError` before implementation.

- [ ] **Step 3: Implement typed nil handling**

Keep `ValidateSubmission#attributes_for(nil)` returning `nil`, but return `failure_for("invalid_submission")` before dereferencing `@submission`. In `PersistSubmission`, preserve nil through initialization and return a `Core::BusinessError` with the existing `invalid_submission` translation before entering the transaction.

- [ ] **Step 4: Repair existing seed state**

After `find_or_create_by!`, call `form.update!(active: true)` when an existing form is inactive, then seed its version. Do not create a new form or version solely to repair the active flag.

- [ ] **Step 5: Run focused tests and seed verification**

Run the command from Step 2, then execute the existing disposable seed idempotency/older-draft repair check and `bin/rails db:seed` twice. Expected: typed failures, successful seed runs, and unchanged counts on the second run.

### Task 5: Final verification

**Files:**
- Verify: all changed files, `db/structure.sql`, and the new design/plan documents.

- [ ] **Step 1: Run the complete automated verification**

Run:

```bash
N_PLUS_ONE=1 bundle exec rails test
bundle exec rubocop
bundle exec brakeman --no-pager
bin/rails zeitwerk:check
git diff --check
jq empty 'postman/Digis API_collection.json'
```

Expected: 0 test failures, no RuboCop offenses in changed files, no Brakeman warnings, Zeitwerk success, clean diff check, and valid JSON.

- [ ] **Step 2: Run fresh-database migration verification**

Create a disposable PostgreSQL database, run `bin/rails db:migrate`, verify the submission immutable trigger, registration snapshot guard, retention-policy activation guard, answer policy guard, and reservation foreign keys, then drop the database. Do not alter production or retain the disposable database.

- [ ] **Step 3: Run a final read-only review**

Inspect `git status`, `git diff --stat`, and the complete diff. Re-run the independent review against the design spec and report any remaining findings before considering the work complete.
