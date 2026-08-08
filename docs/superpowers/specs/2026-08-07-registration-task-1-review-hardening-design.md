# Registration Task 1 Review Hardening

## Goal

Harden the completed registration, versioned-form, encrypted-answer, and retention-policy foundation against the seven defects identified in the final Task 1 review. Keep the planned Task 6 retention purge job out of scope.

## Design

Use layered enforcement that matches the existing registration immutability design:

- Validate duplicate `allowed_option_keys` in both `RegistrationQuestion` and `ValidateSubmission`.
- Make `RegistrationFormSubmission` append-only in the model and with database update/delete guards. Update the on-behalf correction test setup to create the intended submitter instead of mutating an evidence record.
- Once a form submission exists, freeze registration event, ticket type, selected event date, package quantity, admissions-per-unit snapshot, and party-size snapshot in both the model and `90113` database trigger.
- Require each answer retention policy to be active, effective no later than `answered_at`, and compatible with the question type category. Enforce the same invariant in the answer integrity trigger.
- Require a draft-to-active retention policy transition to use a version greater than all existing policies in the same category and jurisdiction. Preserve active-to-retired transitions.
- Convert nil input to a typed `invalid_submission` result in both form services instead of allowing `NoMethodError`.
- Reactivate an existing development seed form before creating or repairing its versions.

## Migration And Schema

Edit the existing `db/migrate/20260727090113_add_registration_immutability_triggers.rb` because this repository is pre-production and Task 1 owns the trigger foundation. Refresh `db/structure.sql` after applying the migration. Do not add compatibility migrations or implement Task 6 purge behavior.

## Tests

Add or update focused tests before implementation for:

- duplicate allowed option keys at publish and submission validation boundaries
- direct model and SQL update attempts against form submissions
- model and SQL changes to registration snapshots after submission
- active/category/effective retention policy acceptance and rejection
- draft-to-active policy version rollback rejection
- nil input results from `ValidateSubmission` and `PersistSubmission`
- development seed repair of inactive existing forms

Run the focused tests first, then the full suite with `N_PLUS_ONE=1`, RuboCop, Brakeman, Zeitwerk, JSON validation, `git diff --check`, and fresh disposable migration checks.

## Non-Goals

- Retention purge jobs, bounded erasure, and scheduled deletion remain planned Task 6 work.
- Registration submission aggregate, payment, approval, consent, export, and other later plan tasks are unchanged.
