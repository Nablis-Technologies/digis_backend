# Task 3 — Collaborators and Event Staff Assignments (Design)

> Source plan: `docs/superpowers/plans/2026-07-17-event-foundation-scheduling-media-implementation.md`, **Task 3 (lines 208–230)**.
> Goal: build the event collaboration surface — partner-organisation collaborators (`EventOrganization`) and explicit individual staff assignments (`EventStaffAssignment`) — with one authoritative authorization resolver and service-driven staff transitions. Owners/admins need no assignment; everyone else needs an *active* assignment to gain non-owner access.

## Current state (already done in Task 1, do NOT recreate)

- Migrations `20260717010400_create_events_event_organizations.rb` and `20260717010500_create_events_event_staff_assignments.rb` exist; tables present in `db/schema.rb` with check constraints, unique indexes, and FK cascades.
- Models `Events::EventOrganization` and `Events::EventStaffAssignment` exist with `self.inheritance_column = nil`, validations, and scopes.
- `Events::EventPolicy` already exposes `owner_or_collaborator?`, `manager_of?`, `staff_of?` helpers using `Organizations::Membership` and `event_staff_assignments`.

## Deliverables (Task 3 file list, lines 213–223)

### 1. Nested CRUD controllers (Core::Common)
- `app/controllers/events/event_organizations_controller.rb`
  - `parent_class = Events::Event`. Conventional CRUD via `Core::Common` (`index/show/create/update/destroy`).
  - `create` validates the target `organization_id` resolves to a real `Organizations::Organization`; the actor must be owner/admin of the **event's** organization (reuse existing `owner_or_collaborator?` semantics through Pundit `create?`).
  - `model_params` permits `:type, :role, :status, :organization_id`.
- `app/controllers/events/event_staff_assignments_controller.rb`
  - `parent_class = Events::Event`. `index/show/create/update/destroy` via `Core::Common`.
  - Custom member actions `suspend`, `revoke`, `change_role` → each calls its `Events::StaffAssignments::*` service (NOT `Core::Common#update`).
  - `create` delegates to `Events::StaffAssignments::Assign` (so assignment is a service, per plan line 227).

### 2. Staff-transition services (`app/services/events/staff_assignments/`)
All `< Core::BaseService`, return `Core::BaseService::Result`, write audit synchronously inside the transaction, publish outbox after commit, and never do external work in-transaction.
- `assign.rb` — creates an assignment (type ∈ manager/staff/scanner/contractor) for `user` on `event`, under `event.lock!`; rejects duplicate (unique scope `event_id+type+user_id`); records audit `event.staff.assigned`.
- `change_role.rb` — changes `type` of an existing assignment; re-validates uniqueness; records `event.staff.role_changed`.
- `suspend.rb` — sets `status: "suspended"` (access immediately fails); records `event.staff.suspended`.
- `revoke.rb` — sets `status: "revoked"` (soft; history retained, access removed); records `event.staff.revoked`.

### 3. Authorization resolver (single source of truth)
- `app/services/events/authorization_resolver.rb` → `Events::AuthorizationResolver`
  - `access_granted?(user, event)` → true if user is SUPER_ADMIN/ADMIN, OR has active `organizations_memberships` (owner/admin/manager) on `event.organization`, OR has an **active** `event_staff_assignment` (manager/staff/scanner/contractor). Expired/suspended/revoked assignments ⇒ false.
  - `role_for(user, event)` → `:super_admin / :admin / :owner / :manager / :staff / :scanner / :contractor / :none`.
  - `can_assign?(actor, event, target_type)` → owner/admin may assign any; manager may assign staff/scanner only (matches plan line 225 "only owner/admin/manager can assign within allowed authority").
- Refactor: `Events::EventPolicy` helpers (`owner_or_collaborator?`, `manager_of?`, `staff_of?`) are re-pointed to call `AuthorizationResolver` so there is exactly one implementation (plan line 229).

### 4. Policy
- `app/policies/events/event_staff_assignment_policy.rb` → `Events::EventStaffAssignmentPolicy`
  - `index?/show?` → `AuthorizationResolver.access_granted?(user, record.event)`.
  - `create?/update?/destroy?` → `can_assign?(user, record.event, record.type)`.
  - `Scope` → assignments whose event the actor can see (reuse `EventPolicy::Scope` logic).

### 5. Serializer
- `app/serializers/events/event_staff_assignment_serializer.rb` — flat, no cycles: `id, type, status, user_id, organization_id, event_id, created_at, updated_at`.

### 6. Routes (`config/routes.rb`)
Nest under the existing `resources :events` block (no new top-level resources):
```ruby
resources :events, only: %i[index show create update] do
  post :publish, on: :member
  resources :event_organizations, only: %i[index show create update destroy]
  resources :event_staff_assignments, only: %i[index show create update destroy] do
    post :suspend, on: :member
    post :revoke, on: :member
    post :change_role, on: :member
  end
end
```

### 7. Tests (RED first)
- `test/models/events/event_staff_assignment_test.rb` — `inheritance_column = nil` regression; uniqueness scope `event_id+type+user_id`; type/status inclusion; that `expired/suspended/revoked` are not "active".
- `test/integration/events/event_staff_assignments_test.rb` — **authorization matrix** (plan line 225): owners/admins need no assignment; staff/scanner/contractor require active assignment; collaborator-org membership alone grants NO access; manager vs staff vs scanner boundaries differ; expired/suspended/revoked fail immediately; only owner/admin/manager can assign; manager cannot assign another manager.
- `test/integration/events/event_organizations_test.rb` — collaborator-org CRUD + that adding one does not grant the partner org's members event access.
- `test/services/events/staff_assignments/{assign,change_role,suspend,revoke}_test.rb` — transition behaviour + synchronous audit + outbox.
- `test/services/events/authorization_resolver_test.rb` — `access_granted?`, `role_for`, `can_assign?` matrix.

### 8. Postman (`postman/Digis API_collection.json`)
Add `Events > Event Organizations` and `Events > Event Staff Assignments` folders (with `:id`/`:event_id` path vars, and the suspend/revoke/change_role member actions). Per project memory rule: update Postman after every API change.

## Constraints (from plan normative sources)
- `Core::Common` only for conventional CRUD; transitions are services (line 7, 227).
- One `Events::AuthorizationResolver`; no configurable event permissions, no duplicate org RBAC (line 229).
- Every command enqueues via durable outbox; no external work inside the transaction (line 20).
- `self.inheritance_column = nil` + regression test for both business-type models (line 19).

## Out of scope (later tasks)
- `Events::EventAuthorizer` (publication/schedule/media) — separate shared abstraction, introduced in its own task.
- Public serializer exposure of staff data is excluded (Phase gate line 337: only owners/admins/managers/staff/scanner see staff surfaces).

## Commit
Stage the listed new/modified files and commit `feat(events): add collaborators and event staff assignments` (plan line 230).
