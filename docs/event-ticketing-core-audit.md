# Event Ticketing Core Audit

## Executive Summary

The corrected `vendor/dscf-core` engine is stronger than the earlier copy because it already includes a real authorization layer, not just authentication and CRUD helpers. It now has Pundit-based authorization, permissions, role-permission joins, role assignment endpoints, expiring role assignments, and permission helper methods on users.

Even with that improvement, it is still not a clean fit for an event ticketing and operations app as-is. It contains a useful set of reusable platform primitives, but it also bakes in supply-chain-financing assumptions, naming, and workflows that will make the ticketing domain harder to model if left unchanged.

The best path is still not to reuse it unchanged. It should be split into three layers:

1. A small reusable platform layer for auth, authorization, audit logging, file storage, pagination, filtering, and JSON response helpers.
2. A ticketing domain layer for events, venues, ticket types, orders, transfers, check-ins, QR scans, offline sync, and operational workflows.
3. A minimal admin/review workflow only where the ticketing domain actually needs approvals, moderation, or manual override handling.

My recommendation is that this should not stay as a permanent `vendor/` copy. If you want to reuse it across more than one app, turn it into a private internal engine gem in a separate repo. If this will only ever serve the ticketing app, fold the reusable bits into the main application and delete the rest.

## What Is Actually Reusable

These parts are worth keeping, but they should be renamed and simplified so they are domain-neutral.

- Auth primitives: JWT issuance, refresh tokens, token parsing, and optional device tracking.
- Authorization primitives: permissions, role-permission joins, Pundit fallback authorization, permission registry, and user permission helper methods.
- Audit logging: the `AuditLog` model and the audit concern are useful for admin actions, event changes, refunds, ticket transfers, and gate operations.
- File attachment helpers: the attachable concern, upload/download helpers, and storage adapter are useful for ticket PDFs, QR payloads, event media, and organizer documents.
- Generic controller utilities: pagination, filtering, and JSON response helpers are broadly reusable.
- Role-based access control: `UserRole`, `Role`, `Permission`, `RolePermission`, and `Authorizable` are now real assets in this codebase, especially because they already support `assigned_by`, expiration, and permission-based policies.

## What The Corrected Engine Actually Adds

Compared with the earlier copy, this version materially improves the platform layer in these ways:

- `Authorizable` integrates Pundit and enforces authorization after actions.
- `ApplicationPolicy` gives a conventional permission-code-based fallback like `resource.action`.
- `Permission` and `RolePermission` create a real permission catalog instead of role-only checks.
- `PermissionRegistry` provides a path for engines or domains to register permissions consistently.
- `User` now has `has_permission?`, `has_any_permission?`, `has_all_permissions?`, `can?`, and `super_admin?`.
- `UserRole` supports `assigned_by` and `expires_at`, which is useful for temporary staff access.
- dedicated endpoints exist for managing role assignments and role permissions.

That means the foundation is no longer just “auth and CRUD”; it is a legitimate early-stage authz platform.

## What Should Be Renamed

The current names reflect a financing platform, not a ticketing platform. They should be replaced before the code grows further.

- `Business` should become something like `Organization`, `OrganizerAccount`, `Tenant`, or `EventOperator`.
- `BusinessType` should become `OrganizationType`, `OrganizerType`, or be removed if it is not truly needed.
- `UserProfile` should become a neutral profile model, such as `Profile` or `AccountProfile`.
- `Document` should become `Attachment` or `IdentityDocument` only if the model is really about verification documents.
- `Review` should become `Approval`, `Moderation`, `WorkflowReview`, or a ticketing-specific review concept if you keep a review flow.
- `RefreshToken` should stay as an auth concept, but its implementation should be reviewed for mobile and offline field usage.
- `Permission` and `Role` can keep their names, but their codes and resource naming should move away from finance-oriented resource names.
- The `Dscf::Core` namespace should be replaced with a domain-neutral namespace.

## What Should Be Removed or Replaced

These pieces are too tied to the financing domain or are too opinionated for a ticketing product.

- Supply-chain-specific profile fields such as `pep_status`, `watchlist_hit`, and `verification_status` should be removed unless your ticketing app has a real compliance/KYC requirement.
- `tin_number` belongs to a business registration domain, not a general ticketing user or organizer model, unless you are explicitly onboarding registered vendors.
- `business_license` handling is only relevant if your platform verifies organizers or venues. If so, rename it to something like `organization_verification_document`.
- The default `Review` workflow actions `submit`, `approve`, `reject`, `request_modification`, and `resubmit` are generic but still feel finance-onboarding oriented. Keep the mechanism only if you truly need workflow approval states.
- The current `Document` enum values `business_license`, `drivers_license`, and `claim` are not ticketing-centric. Replace them with ticketing-oriented document types or remove the enum entirely.
- The `FileStorage::Client` env var naming (`MINIO_API_KEY_DSCF_*`) and routes (`/dscf/core/files`) should be renamed to something product-neutral.

## What Should Be Reworked

These parts are useful, but the current implementation is too coupled to the old project shape.

### Auth

The auth stack is functional, but it is opinionated around email-or-phone login, refresh tokens, and device/IP validation.

For an event ticketing app, this is acceptable only if you need API auth for mobile apps, scanners, and offline sync. Even then, the current IP check in refresh token renewal is risky for mobile and field devices because staff may move between networks frequently.

Recommended changes:

- Keep JWT access tokens if you want a stateless API.
- Keep refresh tokens if you need mobile sessions or scanner devices.
- Remove or relax hard IP binding for refresh token reuse.
- Make device tracking configurable rather than mandatory.
- Separate attendee login from staff/ops login if you expect different trust levels.

### Authorization and RBAC

This corrected engine has a better authorization story than I first gave it credit for.

What is good:

- permission records are explicit and queryable
- role-permission joins are normalized
- user permission helpers are practical
- Pundit fallback policy behavior is a solid base for CRUD resources
- expiring role assignments are useful for temporary staff or support access
- `assigned_by` creates accountability for who granted access

Why it is still not enough for ticketing without redesign:

- permissions are global, not tenant-scoped
- there is no concept of organization-scoped membership permissions
- there is no event-scoped temporary permission model
- there is no scanner-device or gate-level authorization concept
- policy resolution is mostly resource/action based, which is good for CRUD but too thin for ownership and operational rules

For an event platform, you will eventually need permission layers like:

- platform-level permissions
- organization membership roles
- event-level staffing permissions
- temporary scanner/gate permissions
- special-case override permissions for refunds, fraud review, and dispute handling

Recommended changes:

- keep the RBAC foundation
- do not throw away `Permission`, `RolePermission`, `Authorizable`, or `ApplicationPolicy`
- add tenant-aware permission scoping above it
- use organization memberships and event staff assignments as the real business authorization layer
- let global RBAC handle platform staff and cross-cutting admin capabilities

### File Storage

The file subsystem is useful, but it should be validated against the real ticketing needs.

Potential uses in a ticketing app:

- Event banners, hero images, and venue assets.
- Ticket PDFs or downloadable ticket packages.
- QR code payload exports.
- Organizer verification documents.
- Offline scan bundles for gate devices.

Recommended changes:

- If you only need standard upload/download behavior, Active Storage may be simpler than the custom MinIO service layer.
- If you keep the custom service, make the storage backend name and API key lookup product-neutral.
- Add explicit support for signed downloads and offline sync bundles if gate devices need them.
- Review whether central `FileAttachment` records are worth the extra abstraction versus native Active Storage attachments.

### Audit Logging

Audit logging is one of the strongest reusable pieces.

It is a good fit for:

- Event publishing and moderation.
- Ticket transfer approvals or admin overrides.
- Refund approvals and chargeback handling.
- Check-in actions at gates.
- Offline sync reconciliation.

Recommended changes:

- Keep the audit model and audit concern.
- Rename any finance terminology in the payload or serializers.
- Add event-ticketing-specific action names such as `event_created`, `ticket_transferred`, `ticket_scanned`, `offline_scan_synced`, `refund_approved`, and `event_published`.

### Review Workflow

The review workflow is the most likely thing to either become very useful or become dead weight.

For ticketing, a workflow engine only makes sense if you need structured approvals for:

- Event publication.
- Organizer onboarding.
- Venue verification.
- Refund exceptions.
- Fraud or transfer review.

If you do not need that, remove it and keep the codebase simpler.

If you do need it, refactor it hard:

- Replace the default finance-style statuses with ticketing-specific statuses.
- Make the context system explicit and narrow.
- Avoid over-generic controller magic that hides business rules.
- Add tests around state transitions before reusing it.

### Generic Controller Base

`Common`, `JsonResponse`, `Pagination`, `Filterable`, and `Authorizable` are helpful, but the current controller layer is still very coupled to the engine namespace and assumes a specific CRUD shape.

Recommended changes:

- Keep the response, pagination, and authorization helpers if they reduce repetition.
- Simplify the controller base so it does not depend on hidden naming conventions.
- Move business-specific defaults out of the shared layer.
- Prefer explicit controllers for important ticketing flows such as checkout, transfer, scan, and offline sync.

## Ticketing Domain You Still Need To Add

This is the real application surface that the current engine does not provide.

- `Event` with publish state, scheduling, capacity, and visibility.
- `Venue` or `Location` with seating or general admission rules.
- `TicketType` with pricing tiers, inventory, limits, and sale windows.
- `Order` and `OrderItem` for purchases.
- `Ticket` as the issued entitlement.
- `TicketTransfer` for resale and peer transfer flows.
- `ScanSession`, `Gate`, or `CheckIn` for operations at entry points.
- `OfflineScanBatch` or `SyncBundle` for downloaded tickets and delayed validation.
- `Refund`, `Chargeback`, and `Payout` if you handle money movement.
- `Organizer`, `StaffMember`, and `GateAgent` roles or permissions.

The important nuance now is that the engine can help with some of the authorization mechanics for these, but it should not be mistaken for the full authorization model itself.

If these concepts are central, the copied finance engine should not define your domain model for you. It should only provide infrastructure.

## Specific Edits I Would Make First

If you want to keep moving with this codebase, I would make these changes first in order.

1. Rename the namespace and package identity so the app no longer reads as supply-chain financing.
2. Remove or rewrite the finance-only model fields and enums.
3. Decide whether the review workflow is actually needed for ticket publishing or organizer approval.
4. Replace or simplify the custom file attachment stack if Active Storage is enough.
5. Keep auth and RBAC only if they support mobile staff devices, temporary operational permissions, and offline sync realities; otherwise simplify them.
6. Add tenant-aware authorization rules on top of the existing RBAC foundation instead of forcing everything through global roles.
7. Add ticketing domain models and flows before carrying over any more generic abstractions.

## Recommended Target Architecture

The cleanest long-term shape is:

- Main app owns ticketing models, checkout, transfers, check-in, offline sync, and reporting.
- Shared engine owns auth, authorization, audit, storage helpers, pagination, response helpers, and maybe role helpers.
- The shared engine lives outside `vendor/` once it stabilizes.

That gives you a smaller attack surface, easier testing, and less friction when ticketing requirements inevitably diverge from the old financing assumptions.

## Final Recommendation

Do not keep this exactly as a copied vendor gem.

If you expect reuse across multiple products, extract only the truly generic pieces into a private internal engine gem and version it independently. If this is a single product, stop treating it like a reusable gem and move the useful helpers directly into the app while deleting the financing-specific leftovers.

For an event ticketing and operations app, the current code should be treated as a starting scaffold plus a usable early RBAC/authz foundation, not as the domain model.
