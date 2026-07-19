# Core Foundation

## Purpose

This directory documents the app-local `Core` foundation extracted from `vendor/dscf-core`.

The goal is to keep reusable infrastructure in the host app without dragging the old engine and its supply-chain domain assumptions forward.

## What Has Been Extracted

- authentication primitives
- authorization and RBAC primitives
- audit logging primitives
- standardized JSON API response primitives
- generic API controller primitives (common CRUD + filtering + pagination)
- review workflow primitives (model + controller concerns)

## What Was Intentionally Deferred

- `Business`, `BusinessType`, and all financing-shaped domain models
- engine-specific routes and initializers
- file attachment/storage extraction

Those deferred items can be extracted later if real ticketing use cases justify them.

## Namespacing

Runtime code lives in app-local namespaces:

- `app/models/platform/...`
- `app/controllers/platform/...`
- `app/controllers/concerns/platform/...`
- `app/services/platform/...`
- `app/policies/platform/...`
- `app/jobs/platform/...`
- `lib/platform/...`

This keeps the code Zeitwerk-friendly and app-local while leaving room to extract a smaller gem later if the foundation stabilizes.

## Data Model

The current platform slice introduces these tables:

- `core_users`
- `core_refresh_tokens`
- `core_roles`
- `core_user_roles`
- `core_permissions`
- `core_role_permissions`
- `core_audit_logs`
- `core_reviews`

All platform tables use UUID primary keys.

## Testing Strategy

The host app remains Minitest-first with fixtures.

- fixtures provide baseline users, roles, permissions, and assignments
- integration tests drive auth endpoints
- model and service tests cover permission logic and token behavior
- audit behavior is verified with Active Job + model tests
- review primitives are verified with fixtures + model tests

RSpec support from the vendor engine was intentionally not copied.

## New Core Docs

- [Authentication And RBAC](/Users/adoniyas/Documents/Projects/Rails/digis_backend/docs/platform/authentication-and-rbac.md)
- [Auditing](/Users/adoniyas/Documents/Projects/Rails/digis_backend/docs/platform/auditing.md)
- [API Responses And Serialization](/Users/adoniyas/Documents/Projects/Rails/digis_backend/docs/platform/api-responses-and-serialization.md)
- [Common CRUD Foundation](/Users/adoniyas/Documents/Projects/Rails/digis_backend/docs/platform/common-crud-foundation.md)
- [Review Workflow](/Users/adoniyas/Documents/Projects/Rails/digis_backend/docs/platform/review-workflow.md)
