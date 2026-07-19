---
created: 2026-05-31T21:14:50+00:00
branch: add-followable-entities
trigger: compact
restored: false
topic: add-followable-entities
---

# Handoff: add-followable-entities

## Goal

<!-- to be enriched by LLM -->

## Current State

<!-- to be enriched by LLM -->

## Key Decisions

<!-- to be enriched by LLM -->

## Modified Files

- .gitignore
- app/controllers/organizations/organizations_controller.rb
- app/models/organizations/membership.rb
- app/models/organizations/organization.rb
- app/policies/organizations/organization_policy.rb
- app/serializers/organizations/organization_serializer.rb
- config/routes.rb
- db/seeds.rb
- test/fixtures/core_permissions.yml
- test/fixtures/core_role_permissions.yml
- test/integration/organizations/organizations_test.rb
- test/models/organizations/organization_test.rb
- .codegraph/
- .github/agents/
- .github/copilot-instructions.md
- app/controllers/admin/organization_memberships_controller.rb
- app/controllers/admin/organizations_controller.rb
- app/controllers/organizations/owner_organizations_controller.rb
- app/policies/admin/membership_policy.rb
- app/policies/admin/organization_policy.rb
- app/serializers/admin/organization_serializer.rb
- app/serializers/events/public/
- app/serializers/organizations/public/
- config/brakeman.ignore
- docs/
- postman/
- test/integration/admin/organization_memberships_test.rb
- test/integration/admin/organizations_test.rb
- test/integration/organizations/owner_organizations_test.rb
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
- `docs/superpowers/plans/2026-05-17-phone-first-auth-and-organizations.md` (plan)
- `docs/superpowers/plans/2026-05-22-per-action-attributes-plan.md` (plan)
- `docs/superpowers/plans/2026-05-23-serializer-profile-unification.md` (plan)
- `docs/superpowers/plans/2026-05-24-generator-component-selection-and-sensitive-filter.md` (plan)
- `docs/superpowers/plans/2026-05-25-organizations-implementation.md` (plan)
- `docs/superpowers/plans/2026-05-26-admin-rbac-module.md` (plan)
- `docs/superpowers/plans/2026-05-28-venues-and-artists.md` (plan)
- `docs/superpowers/plans/2026-05-30-venues-artists-social-implementation.md` (plan)

## Next Steps

<!-- to be enriched by LLM -->

## Open Questions

<!-- to be enriched by LLM -->
