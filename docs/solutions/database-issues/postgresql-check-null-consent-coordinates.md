---
problem_type: database-integrity
component: ticketing-registration-consents
symptom: PostgreSQL accepted an admission-slot consent requirement with a missing coordinate
root_cause: A CHECK expression using only numeric comparisons evaluates to NULL for NULL input, and PostgreSQL treats NULL CHECK results as allowed.
---

# PostgreSQL CHECK Constraints and Nullable Coordinates

## Problem

The admission-slot branch of `ticketing_consent_requirements_coordinate_check`
used `package_unit_number > 0 AND admission_position > 0`. A direct SQL insert
with one coordinate set to `NULL` bypassed the constraint because the expression
evaluated to `NULL` rather than `FALSE`.

## Solution

Make nullability explicit in the original migration and the checked-in schema:

```sql
acceptance_scope = 'admission_slot'
AND package_unit_number IS NOT NULL
AND package_unit_number > 0
AND admission_position IS NOT NULL
AND admission_position > 0
```

Added a direct `insert_all!` regression test that proves the database rejects a
missing admission-slot coordinate. The application model validation remains as
the earlier feedback layer; the database constraint is the final boundary.

Also removed a duplicate `missing_idempotency_key` locale key. YAML kept the
last duplicate value, which caused acceptance requests to receive a reassignment
message. The single remaining message is operation-neutral.

## Prevention

- Treat every nullable column in a PostgreSQL `CHECK` as requiring an explicit `IS NULL` or `IS NOT NULL` branch.
- Test integrity constraints through direct SQL paths such as `insert_all!` and `update_all`, not only through model validations.
- Keep locale keys unique within each mapping; test user-facing translations when duplicate-key behavior would be misleading.

## Verification

- `bundle exec rails test`: 1552 tests, 4165 assertions, 0 failures, 0 errors.
- `N_PLUS_ONE=1 bundle exec rails test`: 1552 tests, 4165 assertions, 0 failures, 0 errors.
- `bundle exec rubocop`: 675 files, no offenses.
- `bundle exec rails zeitwerk:check`: All is good.
- `bundle exec brakeman -q`: 0 errors, 0 security warnings.
