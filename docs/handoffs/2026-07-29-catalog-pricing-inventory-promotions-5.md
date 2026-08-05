---
created: 2026-07-29T17:06:36+00:00
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

- app/controllers/catalog/product_inventories_controller.rb
- app/controllers/catalog/product_quotes_controller.rb
- app/models/catalog/event_product.rb
- app/models/catalog/inventory_reservation.rb
- app/models/catalog/product_inventory.rb
- app/models/events/event_date.rb
- app/policies/catalog/product_inventory_policy.rb
- app/policies/catalog/product_price_policy.rb
- app/serializers/catalog/product_inventory_serializer.rb
- app/services/catalog/inventory/commit.rb
- app/services/catalog/inventory/expire.rb
- app/services/catalog/inventory/reconcile.rb
- app/services/catalog/inventory/release.rb
- app/services/catalog/inventory/reserve.rb
- app/services/catalog/products/activate.rb
- app/services/catalog/products/create.rb
- app/services/catalog/products/deactivate.rb
- app/services/events/authorization_resolver.rb
- config/locales/catalog/event_product.en.yml
- config/locales/catalog/inventory.en.yml
- config/locales/catalog/inventory_reservation.en.yml
- config/locales/catalog/product_inventory.en.yml
- config/routes.rb
- db/migrate/20260727090020_create_catalog_event_products.rb
- db/migrate/20260728000004_create_catalog_inventory_reservations.rb
- db/seeds/dev.rb
- db/structure.sql
- docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md
- "postman/Digis API_collection.json"
- test/integration/catalog/product_quotes_test.rb
- test/models/catalog/event_product_test.rb
- test/models/catalog/product_price_test.rb
- test/models/ticketing/access_code_test.rb
- test/models/ticketing/invitation_test.rb
- test/models/ticketing/ticket_type_test.rb
- test/services/catalog/pricing/debug_quote_test.rb
- test/services/catalog/pricing/debug_quote_test2.rb
- test/services/catalog/pricing/quote_test.rb
- test/services/events/consent_documents/replace_scope_test.rb
- test/services/ticketing/access_codes/consume_test.rb
- test/services/ticketing/audience/authorize_test.rb
- test/services/ticketing/invitations/claim_test.rb
- app/controllers/catalog/event_products_controller.rb
- app/models/catalog/venue_capacity_reservation.rb
- app/policies/catalog/event_product_policy.rb
- app/serializers/catalog/event_product_serializer.rb
- app/serializers/ticketing/
- app/services/catalog/inventory/reservation_group_lock.rb
- app/services/catalog/inventory/reservation_request.rb
- app/services/catalog/products/create_draft.rb
- app/services/catalog/products/update_inventory_configuration.rb
- db/migrate/20260729000001_create_catalog_venue_capacity_reservations.rb
- docs/handoffs/2026-07-29-catalog-pricing-inventory-promotions-2.md
- docs/handoffs/2026-07-29-catalog-pricing-inventory-promotions-3.md
- docs/handoffs/2026-07-29-catalog-pricing-inventory-promotions-4.md
- docs/handoffs/2026-07-29-catalog-pricing-inventory-promotions.md
- docs/superpowers/plans/2026-07-29-organizer-catalog-hardening-implementation.md
- test/fixtures/catalog/inventory_reservations.yml
- test/fixtures/catalog/product_inventories.yml
- test/integration/catalog/event_products_test.rb
- test/integration/catalog/product_inventories_test.rb
- test/jobs/catalog/
- test/models/catalog/inventory_reservation_test.rb
- test/models/catalog/product_inventory_test.rb
- test/models/catalog/venue_capacity_reservation_test.rb
- test/policies/catalog/
- test/services/catalog/inventory/
- test/services/catalog/products/

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
