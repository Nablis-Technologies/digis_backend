---
created: 2026-06-18T09:28:34+00:00
branch: add-organization-onboarding
trigger: compact
restored: false
topic: add-organization-onboarding
---

# Handoff: add-organization-onboarding

## Goal

<!-- to be enriched by LLM -->

## Current State

<!-- to be enriched by LLM -->

## Key Decisions

<!-- to be enriched by LLM -->

## Modified Files

- .gitignore
- app/controllers/admin/organizations_controller.rb
- app/controllers/concerns/core/membership_management.rb
- app/controllers/organizations/organizations_controller.rb
- app/controllers/organizations/owner_memberships_controller.rb
- app/controllers/organizations/owner_organizations_controller.rb
- app/models/core/user.rb
- app/models/organizations/membership.rb
- app/models/organizations/organization.rb
- app/policies/organizations/membership_policy.rb
- app/policies/organizations/organization_policy.rb
- app/serializers/admin/organization_serializer.rb
- app/serializers/organizations/membership_serializer.rb
- app/serializers/organizations/organization_serializer.rb
- app/serializers/organizations/public/organization_detail_serializer.rb
- app/serializers/organizations/public/organization_list_serializer.rb
- config/environments/development.rb
- config/environments/production.rb
- config/environments/test.rb
- config/routes.rb
- db/migrate/20260525200000_create_organizations_organizations.rb
- db/migrate/20260525200001_create_organizations_memberships.rb
- db/schema.rb
- db/seeds.rb
- test/fixtures/organizations_memberships.yml
- test/fixtures/organizations_organizations.yml
- test/integration/admin/organization_memberships_test.rb
- test/integration/admin/organizations_test.rb
- test/integration/organizations/owner_memberships_test.rb
- test/integration/organizations/owner_organizations_test.rb
- test/models/organizations/membership_test.rb
- test/models/organizations/organization_test.rb
- test/support/core/resource_test.rb
- .codegraph/
- .commandcode/
- .github/agents/
- .github/copilot-instructions.md
- .gitignore.rej
- Oops.rej
- Oops.rej.orig
- app/controllers/admin/verifications_controller.rb
- app/controllers/concerns/verification_callbacks.rb
- app/controllers/organizations/verifications_controller.rb
- app/models/organizations/organization.rb.rej
- app/policies/admin/verification_policy.rb
- app/policies/organizations/verification_policy.rb
- app/services/organizations/
- config/brakeman.ignore
- db/migrate/20260618092246_remove_verification_status_from_organizations.rb
- diffs.json
- docs/
- postman/
- test/test_helper.rb.bak

## Failed Approaches

<!-- to be enriched by LLM -->

## Files to Read

- `docs/superpowers/specs/2026-05-19-short-url-system-cloudflare-workers.md` (spec)
- `docs/superpowers/specs/2026-05-19-short-url-system-design.md` (spec)
- `docs/superpowers/specs/2026-05-22-attribute-visibility-serializer-driven-design.md` (spec)
- `docs/superpowers/specs/2026-05-22-per-action-attributes-design.md` (spec)
- `docs/superpowers/specs/2026-05-23-derive-eager-load-from-profile.md` (spec)
- `docs/superpowers/specs/2026-05-23-i18n-message-localization.md` (spec)
- `docs/superpowers/specs/2026-05-23-policy-visibility-hash.md` (spec)
- `docs/superpowers/specs/2026-05-23-role-based-association-visibility.md` (spec)
- `docs/superpowers/specs/2026-05-23-serializer-profile-unification.md` (spec)
- `docs/superpowers/specs/2026-05-24-association-field-restrictions.md` (spec)
- `docs/superpowers/specs/2026-05-24-domain-module-generator-design.md` (spec)
- `docs/superpowers/specs/2026-05-25-organizations-design.md` (spec)
- `docs/superpowers/specs/2026-05-26-admin-rbac-module.md` (spec)
- `docs/superpowers/specs/2026-05-27-apply-index-scope-design.md` (spec)
- `docs/superpowers/specs/2026-05-28-venues-artists-and-social-features.md` (spec)
- `docs/superpowers/specs/2026-05-29-organizations-social-features.md` (spec)
- `docs/superpowers/specs/2026-05-31-admin-organizations-platform-surface.md` (spec)
- `docs/superpowers/specs/2026-06-01-public-catalog-common-design.md` (spec)
- `docs/superpowers/specs/2026-06-03-owner-membership-endpoints.md` (spec)
- `docs/superpowers/specs/2026-06-04-organization-onboarding-and-verification.md` (spec)
- `docs/superpowers/plans/2026-05-17-phone-first-auth-and-organizations.md` (plan)
- `docs/superpowers/plans/2026-05-22-per-action-attributes-plan.md` (plan)
- `docs/superpowers/plans/2026-05-23-serializer-profile-unification.md` (plan)
- `docs/superpowers/plans/2026-05-24-generator-component-selection-and-sensitive-filter.md` (plan)
- `docs/superpowers/plans/2026-05-25-organizations-implementation.md` (plan)
- `docs/superpowers/plans/2026-05-26-admin-rbac-module.md` (plan)
- `docs/superpowers/plans/2026-05-28-venues-and-artists.md` (plan)
- `docs/superpowers/plans/2026-05-30-venues-artists-social-implementation.md` (plan)
- `docs/superpowers/plans/2026-06-01-public-catalog-common.md` (plan)
- `docs/superpowers/plans/2026-06-01-public-common-implementation.md` (plan)

## Next Steps

<!-- to be enriched by LLM -->

## Open Questions

<!-- to be enriched by LLM -->
