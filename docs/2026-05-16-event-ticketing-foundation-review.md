# Event Ticketing Foundation Review

Date: 2026-05-16

## Purpose

This document reviews the corrected copied `vendor/dscf-core` engine and recommends how to reshape it for a new event ticketing and operations platform.

It answers four questions:

1. What in the current core is worth keeping?
2. What should be removed or rewritten because it is too supply-chain-specific or too generic in the wrong places?
3. Should this foundation stay as a vendored gem/engine?
4. What should the event platform architecture look like before implementation starts?

## Sources Reviewed

- `vendor/dscf-core`
- `/Users/adoniyas/Documents/Obsidian-Vaults/Adoniyas/999 Digis App/EVENT TICKETING PLATFORM – FULL FEATURE LIST.md`
- `/Users/adoniyas/Documents/Obsidian-Vaults/Adoniyas/999 Digis App/000 Improved DB Design.md`
- current app skeleton in this repo

## Executive Recommendation

Do not use the current `dscf_core` engine unchanged as the foundation of the event platform.

The best path is:

1. Keep the event product itself as a modular monolith inside this app.
2. Copy only the truly reusable generic pieces from `dscf_core` into the app or into a much smaller new internal foundation namespace.
3. Do not keep ticketing, orders, events, resale, scanning, discovery, or marketing inside a shared engine yet.
4. If you still want a reusable package, create a much smaller new core later, after the product shape stabilizes.

Short version:

- `dscf_core` has some strong building blocks.
- It also carries too much domain baggage from supply chain financing.
- Event ticketing is operationally and financially sensitive enough that over-generic CRUD abstractions will hurt you in the important domains.

My recommendation is to replace `dscf_core` with either:

- a new lightweight `Digis::Core` style internal foundation, or
- direct in-app modules/concerns for the reusable parts, with extraction delayed until they prove stable.

## What The Current Core Actually Gives You

From the engine code, `dscf_core` currently provides these major capabilities:

### 1. Identity, auth, and authorization

- `Dscf::Core::User`
- JWT access/refresh token flow
- email/phone + password authentication
- roles and user_roles
- permissions and role_permissions
- Pundit-backed `Authorizable`
- permission-aware user helpers like `has_permission?`

### 2. Generic API CRUD tooling

- `Dscf::Core::Common` concern for index/show/create/update
- filtering with Ransack
- pagination
- serializers
- a generator that scaffolds controller/serializer/spec/routes patterns

### 3. Review workflow

- `Dscf::Core::ReviewableModel`
- `Dscf::Core::ReviewableController`
- configurable submit/approve/reject/modify/resubmit flow

### 4. Audit logging

- `Dscf::Core::AuditableModel`
- `Dscf::Core::AuditableController`
- background audit logger job

### 5. File handling

- custom polymorphic `FileAttachment`
- upload/download helpers
- upload concern
- MinIO-oriented file storage client

### 6. Supply-chain-specific domain models

- businesses
- business_types
- addresses
- user_profiles
- documents with hard-coded document types like `business_license`

## What Is Good Enough To Reuse

These are the strongest parts of the current core.

### Audit logging: keep the idea

The audit log model and audit controller concern are worth preserving.

Why it fits the event platform:

- ticket ownership changes need traceability
- refunds and payment adjustments need traceability
- event approval/moderation needs traceability
- scanner and gate disputes need traceability
- organizer staff actions need traceability

Recommended change:

- keep the audit concept
- rename/re-namespace it
- make the event/ticketing app define what gets audited instead of assuming current controller patterns

### Review workflow: keep, but broaden the use case

The reviewable workflow is one of the most reusable parts here.

Good future uses:

- organizer verification
- event approval before publish
- refund approval
- listing moderation
- featured-listing approval

Recommended change:

- keep the engine idea
- rename it away from DSCF
- treat it as a generic workflow/state review module
- do not let it define the main lifecycle of tickets, orders, payments, or check-ins

### File attachment abstraction: keep selectively

The attachment abstraction is useful, especially for:

- organizer logos
- event banners
- artist images
- venue images
- exported offline scanner manifests
- compliance and verification documents

Recommended change:

- keep only if you really want custom storage abstraction over Active Storage
- otherwise strongly consider plain Active Storage first
- remove domain assumptions and simplify download/security behavior

Important note:

The event platform will need much tighter semantics than general file upload:

- public event images
- private organizer verification docs
- downloadable ticket exports
- offline scanner payloads

These should not all behave the same way.

### Authorization and RBAC: keep more of it than I first recommended

The corrected engine has a more complete authorization layer than the earlier copy.

Strong reusable parts:

- explicit `Permission` catalog
- `RolePermission` join model
- `Authorizable` concern using Pundit
- fallback `ApplicationPolicy` convention based on `resource.action`
- expiring `UserRole` assignments
- `assigned_by` on role grants
- `PermissionRegistry` for consistent permission registration

Recommended change:

- keep this as part of the reusable foundation
- but do not confuse global RBAC with the full event-platform permission model
- layer organization membership permissions and event staff permissions above it

The event platform still needs authorization concepts the engine does not model yet:

- organization-scoped permissions
- event-scoped staffing
- gate/scanner device permissions
- temporary event crew access
- refund/fraud override permissions

### Phone-first user identity: keep the direction, not the exact implementation

Your feature list is right to prioritize phone identity.

The current user model already supports phone and optional email. That part maps well.

Recommended change:

- keep phone as the primary identifier
- make email optional
- do not lock the platform into password-first auth
- add OTP/magic-link style flows early in the design

For Ethiopia, phone-first is a better product assumption than classic email/password.

### CRUD generator: keep as a tool, not as architecture

The generic generator can still be useful for:

- admin reference tables
- categories
- cities
- venues
- artist profiles
- support/admin internal tools

But it should not define critical product flows like:

- checkout
- ticket issuance
- resale
- transfer
- refunds
- offline scanning
- fraud review

That logic deserves explicit, domain-driven code.

## What Should Be Removed Or Rewritten

### 1. `Business` and `BusinessType` should not survive as-is

This is the clearest mismatch.

In the current engine, the main business entity is a supply-chain business. In the ticketing platform, your real tenant unit is closer to:

- organization
- organizer team
- venue operator
- promoter group
- artist management

Recommended replacement:

- `organizations`
- `organization_memberships`
- optional `organization_profiles`

This aligns with your improved DB design and future team-based operations.

### 2. Global roles and permissions are useful, but still too flat for ticketing operations

Current `roles`, `user_roles`, `permissions`, and `role_permissions` are meaningful reusable primitives. They are just not enough by themselves for event operations.

You will need permission scopes like:

- platform admin
- support
- fraud analyst
- organization owner
- organization admin
- event manager
- finance manager
- scanner/gate staff
- campaign operator

Recommended replacement:

- keep global RBAC for platform-level staff and shared admin capabilities
- use organization memberships for tenant permissions
- add event-level staff assignments for scanners and temporary crews
- treat global permissions as the base layer, not the whole model

### 3. `Document` is too domain-specific in its current form

Current document types include values like:

- `business_license`
- `drivers_license`
- `claim`

That enum is already opinionated for another product.

For the event platform, document handling should be either:

- app-specific per domain, or
- metadata-driven and configurable

You may later need:

- organizer business license
- event permit
- venue agreement
- insurance proof
- artist contract
- payout KYC document

Recommended change:

- do not keep this enum in shared core
- either move document type enums into the app
- or replace enums with typed metadata plus validations in the relevant domain

### 4. The current auth flow is too narrow

`AuthController` is usable as a starting point, but not enough for your planned product.

You will likely need:

- guest checkout
- account creation during purchase
- OTP login by phone
- organizer/staff login
- device-aware scanner authentication
- session revocation for compromised devices

Recommended change:

- keep token/session concepts
- redesign auth flows around buyer, staff, and scanner use cases

### 5. Generic CRUD should not control critical domains

The `Common` concern is nice for speed, but it encourages an anemic CRUD style.

That is risky in event ticketing, because the core value is not CRUD. It is controlled state transitions and operational correctness.

Domains that should not be built as generic CRUD resources:

- orders
- payments
- refunds
- tickets
- transfers
- resale listings
- check-ins
- offline sync
- payouts
- featured ranking decisions

These should be designed as command-style flows with explicit services/policies.

### 6. Engine-wide CORS and controller behavior should not live in a shared domain gem

`Dscf::Core::ApplicationController` currently sets broad CORS headers.

That is application infrastructure, not business-domain core.

Recommended change:

- move CORS policy to the host app
- keep the foundation layer focused on reusable domain/application concerns

### 7. The namespace and packaging are misleading

Even if you kept some of this code, `Dscf::Core` is the wrong conceptual package for the new product.

If you retain a shared layer, rename it completely.

Suggested directions:

- `Digis::Core`
- `Digis::Foundation`
- `Core`

Avoid carrying financing-product terms into the event product.

## Gem Or Not Gem?

This is the most important structural decision.

## Recommendation

Do not keep the full reusable foundation as a vendored gem right now.

Instead:

1. build the event platform inside the app as a modular monolith
2. copy the few stable generic pieces you need
3. extract a smaller gem later only after patterns stabilize

## Why I Recommend Against A Full Shared Gem Right Now

### 1. Your event product is still expanding fast

You already know the current feature list is incomplete. You mentioned future or additional needs like:

- follows for artists, venues, organizers
- location-based recommendations
- featured listings
- SMS/email campaigns
- resale and transfer flows
- offline scanning

That means your model boundaries are still moving.

If you force this too early into a shared gem:

- migrations get harder to reason about
- namespace friction increases
- release coordination gets harder
- you are tempted to keep things generic too early

### 2. Ticketing has high domain specificity

The difficult parts of this app are not generic foundation concerns.

They are highly specific:

- inventory correctness
- payment correctness
- ownership transfer correctness
- duplicate-scan prevention
- offline reconciliation
- fraud traceability

Those should stay close to the app, where product decisions are explicit.

### 3. Premature extraction usually creates fake reuse

A lot of teams extract “shared core” too early and then spend months fighting it.

What usually happens:

- shared gem becomes a dumping ground
- domain-specific logic leaks into “core”
- app teams stop trusting the abstraction
- changes become slower than if code had stayed local

## When A Gem Does Make Sense

A shared gem becomes reasonable if all three are true:

1. the abstraction has already survived one real product cycle
2. at least two apps genuinely need the same behavior
3. the API boundary is stable enough that change is slowing down

That is not where this product is yet.

## Best Practical Option

### Option A: Keep `dscf_core` as-is and adapt it

Pros:

- fastest initial bootstrap
- least short-term copying

Cons:

- wrong mental model
- wrong domain names
- too much inherited baggage
- encourages over-generic design

Verdict:

Not recommended.

### Option B: Copy the reusable generic parts into this app and refactor them

Pros:

- fastest path to a clean ticketing-focused foundation
- easiest to reshape
- no engine namespace friction
- domain code stays explicit

Cons:

- some short-term duplication
- later extraction still needed if multiple apps reuse it

Verdict:

Recommended now.

### Option C: Build a brand-new small internal engine now

Pros:

- clean separation
- nice long-term architecture if kept small

Cons:

- more upfront work
- still easy to over-extract too early

Verdict:

Only do this if you are disciplined enough to keep it tiny and generic.

My practical recommendation:

- start with Option B
- evolve toward Option C later

## What The New Foundation Should Look Like

If you rebuild the reusable layer, keep it small.

### Foundation scope that is reasonable

- phone-first user identity primitives
- token/session handling
- audit logging
- review workflow
- attachment/storage abstraction if you decide not to use plain Active Storage
- pagination/filter helpers for low-risk admin resources
- shared policy/helper modules

### Foundation scope that should stay out

- events
- venues
- artists
- organizations as business rules
- ticket types
- orders
- payments
- refunds
- tickets
- scans
- resale marketplace
- campaigns
- recommendations
- featured rankings

These are product domains, not core plumbing.

## Recommended Product Architecture

Your improved schema document is directionally strong. I would use it as the starting point.

I recommend a modular monolith with bounded domains inside the Rails app.

## Suggested Domains

### 1. Identity Domain

- users
- user_profiles
- phone verifications
- sessions
- devices
- platform roles

Notes:

- keep buyer identity simple
- support guest checkout merging into real accounts later
- add staff/scanner device handling early

### 2. Organization Domain

- organizations
- organization_memberships
- organization_profiles
- organization_verifications

Notes:

- this replaces `businesses`
- model real team-based event operations

### 3. Event Domain

- events
- event_settings
- event_features
- event_series
- event_staff_assignments

Notes:

- keep event identity clean
- do not overload `events` with payment, access, or scan state

### 4. Venue and Talent Domain

- venues
- venue_profiles
- artists
- event_artists

Why:

You explicitly mentioned following artists, venues, and organizers. These should be first-class entities, not just strings on the event record.

### 5. Discovery Domain

- categories
- event_tags
- cities or market regions
- featured_event_slots
- follow_relationships
- recommendation_signals

Why:

Discovery is not just a UI concern for your product. It is part of the business model.

For example:

- location-based ranking
- featured placement
- follows
- “near me” events

### 6. Access and Commerce Domain

- inventory_pools
- ticket_types
- promo_codes
- orders
- order_items
- payments
- refunds
- payouts
- commissions

Notes:

- your improved schema is correct to separate orders from payments
- also plan for organizer settlement/payout tracking early, even if you postpone payouts operationally

### 7. Ticket Ownership Domain

- tickets
- ticket_transfers
- resale_listings
- resale_transactions
- ticket_ownership_events

Why:

Resale and transfer are not small add-ons. They are core ownership flows.

This domain needs an append-only history mindset.

For disputes, you want to answer:

- who originally bought the ticket?
- who currently owns it?
- was it gifted, resold, voided, or refunded?
- what was the chain of custody?

### 8. Attendance and Gate Ops Domain

- attendance_records
- checkin_logs
- scanner_devices
- offline_sync_batches
- offline_ticket_snapshots

This domain deserves special care because venue internet will be unreliable.

Design principles:

- first scan wins
- duplicate attempts are logged, not silently ignored
- offline manifests are versioned
- sync conflicts are explicit
- check-in history is append-only

### 9. Communication and Growth Domain

- announcements
- campaigns
- campaign_recipients
- delivery_logs
- notification_preferences

Why:

You already expect:

- SMS campaigns
- email campaigns
- reminders
- organizer remarketing

This should be a real domain, not an afterthought.

### 10. Trust, Fraud, and Support Domain

- fraud_flags
- support_cases
- moderation_actions
- audit_logs

Why:

Ticketing platforms live or die on trust:

- duplicate QR complaints
- resale disputes
- refund disputes
- organizer abuse

## Changes I Would Make To Your Improved DB Direction

Your improved DB design is good. I would strengthen it in these places.

### 1. Add first-class follow relationships

Because you want users to follow:

- artists
- venues
- organizers

Use a polymorphic or typed follow table, for example:

- follower_user_id
- followable_type
- followable_id
- notification_preferences

### 2. Add first-class featured placement

Do not bury featured logic in event flags only.

Better:

- featured_slots
- featured_campaigns
- sponsored placements

This gives you clearer monetization and scheduling.

### 3. Add payout/settlement tracking early

Your current improved schema covers orders, payments, refunds. Good.

Add settlement thinking too:

- organizer payouts
- platform commission
- payout status
- payout reference

Even if you do manual settlement at first, the ledger should exist.

### 4. Strengthen ticket history

A single `tickets.status` field is not enough by itself for resale/transfer disputes.

Add a history/event table for ownership and status transitions.

Examples:

- issued
- transferred_out
- transferred_in
- listed_for_resale
- sold_on_resale
- refunded
- voided
- checked_in

### 5. Model scanner devices and offline sync explicitly

Offline scanning is operationally important enough to deserve its own persistence.

At minimum add:

- scanner_devices
- scanner_sessions
- offline_sync_batches
- checkin_conflicts

### 6. Separate recommendation inputs from recommendation outputs

For location-based recommendations, start simple.

Track signals like:

- user city
- recent viewed events
- followed entities
- previous attendance
- venue proximity
- featured boost

Then generate ranked results in application logic. Do not over-normalize ML-style tables too early.

## What Should Be MVP vs Later

A common risk here is trying to build Eventbrite, Dice, Partiful, and a CRM all at once.

I recommend this MVP shape:

### MVP

- phone-first identity
- organizer organizations and memberships
- event creation
- ticket types and inventory
- checkout and payment
- QR tickets
- scanner UI
- offline scan download/sync
- audit logs
- basic support/admin visibility

### V1

- transfer/gifting
- controlled resale
- organizer verification workflow
- entry logs and fraud flags
- reminders
- attendee profile and ticket wallet

### V2

- follows
- location-based recommendations
- featured placements
- SMS/email campaigns
- richer analytics
- promo and growth tooling

### Later

- white-label
- enterprise events
- more advanced ranking
- deeper campaign automation

## Detailed Keep / Change / Remove Summary

## Keep

- audit logging concept
- review workflow concept
- phone-first user concept
- reusable upload abstraction only if you truly need custom storage
- CRUD generator for low-risk resources

## Change Heavily

- auth flows
- roles/permissions model
- documents model
- namespaces
- controller abstractions
- file access rules

## Remove From Shared Core

- businesses
- business_types
- supply-chain naming
- supply-chain-specific document enums
- broad application concerns like CORS

## Concrete Refactor Proposal

If I were restructuring this codebase before product build-out, I would do it in this order:

1. Stop treating `vendor/dscf-core` as the long-term product foundation.
2. Create a new internal namespace for reusable platform concerns.
3. Move or copy these pieces first:
   - audit log
   - review workflow
   - auth/session primitives
   - optional file attachment abstraction
4. Delete or ignore these pieces from the shared layer:
   - business
   - business_type
   - DSCF document enums
   - supply-chain routes/controllers
5. Build the event platform domains directly in the app:
   - organizations
   - events
   - ticketing
   - attendance
   - resale
   - communication
   - discovery

## Final Recommendation

The project should not be “`dscf_core` plus event tables.”

It should be:

- a new event platform architecture
- with a small reused foundation
- and explicit domain modules for ticketing and operations

The strongest practical answer is:

- copy the truly generic parts you trust
- rename and simplify them
- keep the real event product logic in the app
- only extract a clean shared gem later if repeated reuse proves it deserves to exist

If you do that, you get the best balance of:

- speed now
- less accidental complexity
- better domain clarity
- easier future extraction
- lower risk in payments, ticket ownership, and gate operations

## Recommended Next Step

Before coding features, write the app as a modular monolith plan around these first implementation slices:

1. identity + organizations
2. events + ticket types + inventory
3. checkout + payments + ticket issuance
4. scanner + offline sync + check-in logging
5. transfers/resale/history
6. discovery + follows + featured + campaigns

That sequence matches both product risk and architecture risk.
