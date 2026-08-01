---
created: 2026-07-31T13:29:37+00:00
branch: feat/catalog-pricing-inventory-promotions
trigger: compact
restored: false
topic: catalog-pricing-inventory-promotions
---

# Handoff: catalog-pricing-inventory-promotions

## Goal

<!-- to be enriched by LLM -->

## Current State

<!-- to be enriched by LLM -->

## Key Decisions

<!-- to be enriched by LLM -->

## Modified Files

- app/controllers/catalog/product_access_zones_controller.rb
- app/controllers/catalog/product_accesses_controller.rb
- app/controllers/catalog/product_date_allocations_controller.rb
- app/models/catalog/product_access.rb
- app/models/catalog/product_access_zone.rb
- app/policies/catalog/product_access_policy.rb
- app/policies/catalog/product_access_zone_policy.rb
- app/policies/catalog/product_date_allocation_policy.rb
- app/serializers/catalog/product_access_serializer.rb
- app/serializers/catalog/product_access_zone_serializer.rb
- app/serializers/catalog/product_date_allocation_serializer.rb
- config/locales/catalog/product_access.en.yml
- config/locales/catalog/product_access_zone.en.yml
- config/locales/catalog/product_date_allocation.en.yml
- config/routes.rb
- db/seeds/dev.rb
- "postman/Digis API_collection.json"
- test/services/events/recurrence/materialize_test.rb
- .playwright-mcp/
- docs/handoffs/2026-07-30-catalog-pricing-inventory-promotions-2.md
- docs/handoffs/2026-07-31-catalog-pricing-inventory-promotions-2.md
- docs/handoffs/2026-07-31-catalog-pricing-inventory-promotions.md
- final-hero.png
- final-relay.png
- full-page.png
- hero-desktop.png
- hero-v2-top.png
- hero-v3-canvas.png
- test/models/catalog/product_access_test.rb
- test/models/catalog/product_access_zone_test.rb
- test/models/catalog/product_date_allocation_test.rb
- test/services/catalog/accesses/
- test/services/catalog/date_allocations/
- work-section.png
- work-v2.png

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
- `docs/superpowers/specs/2026-07-20-event-collaborators-staff-assignments-design.md` (spec)
- `docs/superpowers/specs/2026-07-23-idempotency-assertions-design.md` (spec)
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
- `docs/superpowers/plans/2026-07-17-catalog-pricing-inventory-promotions-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-controlled-resale-marketplace-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-event-foundation-scheduling-media-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-event-platform-core-foundation.md` (plan)
- `docs/superpowers/plans/2026-07-17-event-platform-master-roadmap.md` (plan)
- `docs/superpowers/plans/2026-07-17-launch-hardening-observability-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-orders-payments-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-refunds-finance-settlement-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-registration-consent-privacy-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-scanner-offline-admission-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-streaming-addons-links-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-17-ticket-packages-credentials-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-20-event-collaborators-staff-assignments.md` (plan)
- `docs/superpowers/plans/2026-07-23-idempotency-assertions.md` (plan)
- `docs/superpowers/plans/2026-07-24-platform-legal-documents-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-28-rails-test-speed-implementation.md` (plan)
- `docs/superpowers/plans/2026-07-29-organizer-catalog-hardening-implementation.md` (plan)

## Next Steps

<!-- to be enriched by LLM -->

## Open Questions

<!-- to be enriched by LLM -->
