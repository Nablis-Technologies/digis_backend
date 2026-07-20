# Task 3 — Collaborators and Event Staff Assignments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the event collaboration surface — partner-organisation collaborators (`EventOrganization`) and explicit individual staff assignments (`EventStaffAssignment`) — behind one `Events::AuthorizationResolver`, with service-driven staff transitions and a full authorization-matrix test suite.

**Architecture:** `Core::Common` handles conventional nested CRUD for both collaborators and staff records. Staff *transitions* (assign / change_role / suspend / revoke) are each one `Core::BaseService` command invoked by a member controller action. A single `Events::AuthorizationResolver` is the only source of access truth; `Events::EventPolicy` helpers delegate to it. PostgreSQL owns uniqueness/status invariants; Pundit owns authorization; AMS serializers bound the response; Solid Queue owns only after-commit work.

**Tech Stack:** Ruby 3.4, Rails 8.1 API-only, PostgreSQL UUIDs, Pundit, ActiveModelSerializers, Minitest fixtures.

---

## File map

**Create**
- `app/services/events/authorization_resolver.rb`
- `app/controllers/events/event_organizations_controller.rb`
- `app/controllers/events/event_staff_assignments_controller.rb`
- `app/services/events/staff_assignments/assign.rb`
- `app/services/events/staff_assignments/change_role.rb`
- `app/services/events/staff_assignments/suspend.rb`
- `app/services/events/staff_assignments/revoke.rb`
- `app/policies/events/event_staff_assignment_policy.rb`
- `app/serializers/events/event_staff_assignment_serializer.rb`
- `config/locales/events/staff_assignment.en.yml`
- `test/models/events/event_staff_assignment_test.rb`
- `test/integration/events/event_organizations_test.rb`
- `test/integration/events/event_staff_assignments_test.rb`
- `test/services/events/authorization_resolver_test.rb`
- `test/services/events/staff_assignments/assign_test.rb`
- `test/services/events/staff_assignments/change_role_test.rb`
- `test/services/events/staff_assignments/suspend_test.rb`
- `test/services/events/staff_assignments/revoke_test.rb`
- `test/fixtures/events_event_organizations.yml`
- `test/fixtures/events_event_staff_assignments.yml`

**Modify**
- `config/routes.rb` (nest `event_organizations` + `event_staff_assignments` under `resources :events`)
- `app/policies/events/event_policy.rb` (delegate helpers to `AuthorizationResolver`)
- `config/locales/events/event.en.yml` (add `event_organization` / `event_staff_assignment` success/error keys)
- `postman/Digis API_collection.json` (add two request folders)

**Already exist (do NOT recreate)** — migrations `20260717010400`/`20260717010500`, models `Events::EventOrganization` & `Events::EventStaffAssignment`, and `Events::EventPolicy` base. This plan adds the missing tests, resolver, services, controllers, policy, serializer, routes, locales.

Run all commands with: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails …`

---

## Task 1: Authorization resolver + regression/inheritance tests

**Files:**
- Create: `app/services/events/authorization_resolver.rb`
- Create: `test/services/events/authorization_resolver_test.rb`
- Create: `test/models/events/event_staff_assignment_test.rb`

- [ ] **Step 1: Write the failing resolver + model tests**

```ruby
# test/services/events/authorization_resolver_test.rb
require "test_helper"

class Events::AuthorizationResolverTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing) # org two is verified-ish; see fixtures
    @owner = core_users(:organizer_owner)
    @outsider = core_users(:attendee)
  end

  test "super admin and admin always have access" do
    assert Events::AuthorizationResolver.access_granted?(core_users(:super_admin), @event)
    assert Events::AuthorizationResolver.access_granted?(core_users(:admin), @event)
  end

  test "organization owner/admin/manager have access without assignment" do
    assert Events::AuthorizationResolver.access_granted?(@owner, @event)
  end

  test "outsider without assignment has no access" do
    refute Events::AuthorizationResolver.access_granted?(@outsider, @event)
  end

  test "active staff assignment grants access; suspended/revoked/expired do not" do
    active = Events::EventStaffAssignment.create!(event: @event, user: @outsider,
      organization: @event.organization, type: "staff", status: "active")
    assert Events::AuthorizationResolver.access_granted?(@outsider, @event)
    active.update!(status: "suspended")
    refute Events::AuthorizationResolver.access_granted?(@outsider, @event)
    active.update!(status: "revoked")
    refute Events::AuthorizationResolver.access_granted?(@outsider, @event)
    active.update!(status: "expired")
    refute Events::AuthorizationResolver.access_granted?(@outsider, @event)
  end

  test "role_for reflects assignment type" do
    Events::EventStaffAssignment.create!(event: @event, user: @outsider,
      organization: @event.organization, type: "scanner", status: "active")
    assert_equal :scanner, Events::AuthorizationResolver.role_for(@outsider, @event)
  end

  test "can_assign: owner/admin may assign managers; manager may not" do
    assert Events::AuthorizationResolver.can_assign?(@owner, @event, "manager")
    assert Events::AuthorizationResolver.can_assign?(@owner, @event, "staff")
    # A plain staff user cannot assign anyone:
    staff_user = core_users(:staff)
    Events::EventStaffAssignment.create!(event: @event, user: staff_user,
      organization: @event.organization, type: "staff", status: "active")
    refute Events::AuthorizationResolver.can_assign?(staff_user, @event, "staff")
  end
end
```

```ruby
# test/models/events/event_staff_assignment_test.rb
require "test_helper"

class Events::EventStaffAssignmentTest < ActiveSupport::TestCase
  test "disables STI via inheritance_column = nil" do
    assert_nil Events::EventStaffAssignment.inheritance_column
  end

  test "type and status must be in the allowed sets" do
    assignment = Events::EventStaffAssignment.new(
      event: events_events(:ready_listing),
      user: core_users(:attendee),
      organization: organizations_organizations(:two),
      type: "wizard", status: "asleep"
    )
    refute assignment.valid?
    assert_includes assignment.errors[:type], "is not included in the list"
    assert_includes assignment.errors[:status], "is not included in the list"
  end

  test "duplicate user+event+type is rejected" do
    base = { event: events_events(:ready_listing), user: core_users(:attendee),
             organization: organizations_organizations(:two) }
    Events::EventStaffAssignment.create!(**base, type: "staff", status: "active")
    dup = Events::EventStaffAssignment.new(**base, type: "staff", status: "active")
    refute dup.valid?
    assert_includes dup.errors[:user_id], "duplicate_staff_assignment"
  end

  test "active? is true only for status active" do
    a = Events::EventStaffAssignment.create!(event: events_events(:ready_listing),
      user: core_users(:attendee), organization: organizations_organizations(:two),
      type: "staff", status: "active")
    assert a.active?
    a.update!(status: "suspended")
    refute a.active?
  end
end
```

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/authorization_resolver_test.rb test/models/events/event_staff_assignment_test.rb`
Expected: failures — `Events::AuthorizationResolver` is not defined; the `duplicate_staff_assignment` / `wizard`/`asleep` assertions depend on model behavior that may already pass (model exists) but the resolver tests will fail.

- [ ] **Step 3: Implement the resolver**

```ruby
# app/services/events/authorization_resolver.rb
# frozen_string_literal: true

module Events
  # Single source of truth for who may access or mutate an event and its
  # collaborator/staff records. Do NOT duplicate this logic in policies or
  # controllers — delegate to it.
  module AuthorizationResolver
    module_function

    ACCESS_STATUSES = %w[active].freeze
    STAFF_TYPES = %w[manager staff scanner contractor].freeze

    def access_granted?(user, event)
      return false if user.nil? || event.nil?
      return true if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")

      organization_admin_or_owner?(user, event) || active_assignment?(user, event)
    end

    def role_for(user, event)
      return :none if user.nil? || event.nil?
      return :super_admin if user.has_role?("SUPER_ADMIN")
      return :admin if user.has_role?("ADMIN")

      membership = Organizations::Membership
                   .where(user:, organization: event.organization, status: "active")
                   .where(role: %w[owner admin manager]).first
      return membership.role.to_sym if membership

      assignment = event.event_staff_assignments
                   .where(user:, status: "active").first
      assignment&.type&.to_sym || :none
    end

    def can_assign?(actor, event, target_type)
      return false if actor.nil? || event.nil?

      role = role_for(actor, event)
      return true if %i[super_admin admin owner].include?(role)

      # Managers may assign staff/scanner only, never other managers/contractors beyond their grade.
      role == :manager && %w[staff scanner].include?(target_type.to_s)
    end

    private

    def organization_admin_or_owner?(user, event)
      Organizations::Membership
        .where(user:, organization: event.organization, status: "active")
        .where(role: %w[owner admin manager])
        .exists?
    end

    def active_assignment?(user, event)
      event.event_staff_assignments
           .where(user:, status: "active")
           .exists?
    end
  end
end
```

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/authorization_resolver_test.rb test/models/events/event_staff_assignment_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/services/events/authorization_resolver.rb \
  test/services/events/authorization_resolver_test.rb \
  test/models/events/event_staff_assignment_test.rb
git commit -m "feat(events): add authorization resolver and staff assignment model tests"
```

---

## Task 2: Staff-transition services (assign / change_role / suspend / revoke)

**Files:**
- Create: `app/services/events/staff_assignments/assign.rb`
- Create: `app/services/events/staff_assignments/change_role.rb`
- Create: `app/services/events/staff_assignments/suspend.rb`
- Create: `app/services/events/staff_assignments/revoke.rb`
- Create: `test/services/events/staff_assignments/assign_test.rb`
- Create: `test/services/events/staff_assignments/change_role_test.rb`
- Create: `test/services/events/staff_assignments/suspend_test.rb`
- Create: `test/services/events/staff_assignments/revoke_test.rb`
- Create: `config/locales/events/staff_assignment.en.yml`

- [ ] **Step 1: Write the failing service tests**

```ruby
# test/services/events/staff_assignments/assign_test.rb
require "test_helper"

class Events::StaffAssignments::AssignTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @actor = core_users(:organizer_owner)
    @user = core_users(:attendee)
  end

  test "assigns an active staff member and writes an audit row" do
    assert_difference -> { Events::EventStaffAssignment.count }, 1 do
      result = Events::StaffAssignments::Assign.call(
        event: @event, actor: @actor, user: @user,
        organization: @event.organization, type: "staff"
      )
      assert result.success?, result.error.inspect
    end
    assignment = Events::EventStaffAssignment.last
    assert_equal "active", assignment.status
    assert_equal "staff", assignment.type
    assert @event.audit_logs.for_action("event.staff.assigned").exists?
  end

  test "rejects a duplicate user+event+type" do
    Events::StaffAssignments::Assign.call(event: @event, actor: @actor, user: @user,
      organization: @event.organization, type: "staff")
    result = Events::StaffAssignments::Assign.call(event: @event, actor: @actor, user: @user,
      organization: @event.organization, type: "staff")
    assert result.failure?
    assert_equal "duplicate_assignment", result.error.code
  end
end
```

```ruby
# test/services/events/staff_assignments/change_role_test.rb
require "test_helper"

class Events::StaffAssignments::ChangeRoleTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @actor = core_users(:organizer_owner)
    @user = core_users(:attendee)
    @assignment = Events::EventStaffAssignment.create!(event: @event, user: @user,
      organization: @event.organization, type: "staff", status: "active")
  end

  test "changes the assignment type and audits it" do
    result = Events::StaffAssignments::ChangeRole.call(assignment: @assignment, actor: @actor, type: "scanner")
    assert result.success?
    assert_equal "scanner", @assignment.reload.type
    assert @event.audit_logs.for_action("event.staff.role_changed").exists?
  end
end
```

```ruby
# test/services/events/staff_assignments/suspend_test.rb
require "test_helper"

class Events::StaffAssignments::SuspendTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @actor = core_users(:organizer_owner)
    @user = core_users(:attendee)
    @assignment = Events::EventStaffAssignment.create!(event: @event, user: @user,
      organization: @event.organization, type: "staff", status: "active")
  end

  test "suspends the assignment and removes access" do
    Events::StaffAssignments::Suspend.call(assignment: @assignment, actor: @actor)
    assert_equal "suspended", @assignment.reload.status
    refute Events::AuthorizationResolver.access_granted?(@user, @event)
  end
end
```

```ruby
# test/services/events/staff_assignments/revoke_test.rb
require "test_helper"

class Events::StaffAssignments::RevokeTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @actor = core_users(:organizer_owner)
    @user = core_users(:attendee)
    @assignment = Events::EventStaffAssignment.create!(event: @event, user: @user,
      organization: @event.organization, type: "staff", status: "active")
  end

  test "revokes (soft) the assignment, retains the row, removes access" do
    Events::StaffAssignments::Revoke.call(assignment: @assignment, actor: @actor)
    assert_equal "revoked", @assignment.reload.status
    assert Events::EventStaffAssignment.exists?(@assignment.id)
    refute Events::AuthorizationResolver.access_granted?(@user, @event)
  end
end
```

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/staff_assignments`
Expected: failures — the four service classes are undefined.

- [ ] **Step 3: Add locale messages**

```yaml
# config/locales/events/staff_assignment.en.yml
# frozen_string_literal: true

en:
  events:
    staff_assignment:
      success:
        assign: "Staff assigned successfully"
        change_role: "Staff role changed successfully"
        suspend: "Staff suspended successfully"
        revoke: "Staff revoked successfully"
      errors:
        assign: "Failed to assign staff"
        change_role: "Failed to change staff role"
        suspend: "Failed to suspend staff"
        revoke: "Failed to revoke staff"
        duplicate_assignment: "User already has this role on the event"
        invalid_type: "Invalid staff type"
```

- [ ] **Step 4: Implement the four services**

```ruby
# app/services/events/staff_assignments/assign.rb
# frozen_string_literal: true

module Events
  module StaffAssignments
    class Assign < Core::BaseService
      def initialize(event:, actor:, user:, organization:, type:)
        @event = event
        @actor = actor
        @user = user
        @organization = organization
        @type = type.to_s
      end

      def call
        return type_error unless Events::EventStaffAssignment::TYPES.include?(@type)
        return permission_error unless Events::AuthorizationResolver.can_assign?(@actor, @event, @type)

        assignment = nil
        Events::Event.transaction do
          @event.lock!
          if Events::EventStaffAssignment.exists?(event: @event, user: @user, type: @type)
            return duplicate_error
          end

          assignment = Events::EventStaffAssignment.create!(
            event: @event, user: @user, organization: @organization,
            type: @type, status: "active"
          )
          assignment.record_audit!("event.staff.assigned", actor: @actor,
            audited_changes: { user_id: @user.id, type: @type })
        end
        success(assignment)
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.assign"),
          code: "invalid_assignment", status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      def type_error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invalid_type"),
          code: "invalid_type", status: :unprocessable_entity
        )
      end

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("errors.forbidden"), code: "forbidden", status: :forbidden
        )
      end

      def duplicate_error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.duplicate_assignment"),
          code: "duplicate_assignment", status: :unprocessable_entity
        )
      end
    end
  end
end
```

```ruby
# app/services/events/staff_assignments/change_role.rb
# frozen_string_literal: true

module Events
  module StaffAssignments
    class ChangeRole < Core::BaseService
      def initialize(assignment:, actor:, type:)
        @assignment = assignment
        @actor = actor
        @type = type.to_s
      end

      def call
        return type_error unless Events::EventStaffAssignment::TYPES.include?(@type)
        return permission_error unless Events::AuthorizationResolver.can_assign?(@actor, @assignment.event, @type)

        Events::Event.transaction do
          @assignment.lock!
          previous = @assignment.type
          @assignment.update!(type: @type)
          @assignment.record_audit!("event.staff.role_changed", actor: @actor,
            audited_changes: { type: { old: previous, new: @type } })
        end
        success(@assignment)
      end

      private

      def type_error
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invalid_type"),
          code: "invalid_type", status: :unprocessable_entity
        )
      end

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("errors.forbidden"), code: "forbidden", status: :forbidden
        )
      end
    end
  end
end
```

```ruby
# app/services/events/staff_assignments/suspend.rb
# frozen_string_literal: true

module Events
  module StaffAssignments
    class Suspend < Core::BaseService
      def initialize(assignment:, actor:)
        @assignment = assignment
        @actor = actor
      end

      def call
        return permission_error unless Events::AuthorizationResolver.can_assign?(@actor, @assignment.event, @assignment.type)

        Events::Event.transaction do
          @assignment.lock!
          @assignment.update!(status: "suspended")
          @assignment.record_audit!("event.staff.suspended", actor: @actor)
        end
        success(@assignment)
      end

      private

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("errors.forbidden"), code: "forbidden", status: :forbidden
        )
      end
    end
  end
end
```

```ruby
# app/services/events/staff_assignments/revoke.rb
# frozen_string_literal: true

module Events
  module StaffAssignments
    class Revoke < Core::BaseService
      def initialize(assignment:, actor:)
        @assignment = assignment
        @actor = actor
      end

      def call
        return permission_error unless Events::AuthorizationResolver.can_assign?(@actor, @assignment.event, @assignment.type)

        Events::Event.transaction do
          @assignment.lock!
          @assignment.update!(status: "revoked")
          @assignment.record_audit!("event.staff.revoked", actor: @actor)
        end
        success(@assignment)
      end

      private

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("errors.forbidden"), code: "forbidden", status: :forbidden
        )
      end
    end
  end
end
```

- [ ] **Step 5: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/events/staff_assignments`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/services/events/staff_assignments config/locales/events/staff_assignment.en.yml \
  test/services/events/staff_assignments
git commit -m "feat(events): add staff assignment transition services"
```

---

## Task 3: Policy, serializer, and controller delegation

**Files:**
- Create: `app/policies/events/event_staff_assignment_policy.rb`
- Create: `app/serializers/events/event_staff_assignment_serializer.rb`
- Create: `app/controllers/events/event_organizations_controller.rb`
- Create: `app/controllers/events/event_staff_assignments_controller.rb`
- Modify: `app/policies/events/event_policy.rb`
- Modify: `config/routes.rb`
- Modify: `config/locales/events/event.en.yml`

- [ ] **Step 1: Write the failing controller/integration tests**

```ruby
# test/integration/events/event_staff_assignments_test.rb
require "test_helper"

class EventStaffAssignmentsTest < ActionDispatch::IntegrationTest
  def setup
    @event = events_events(:ready_listing)
    @owner_headers = owner_headers
    @attendee_headers = attendee_headers
  end

  test "owner can list and create a staff assignment" do
    post "/events/#{@event.id}/event_staff_assignments",
         headers: @owner_headers, as: :json,
         params: { event_staff_assignment: { user_id: core_users(:attendee).id,
                   organization_id: @event.organization_id, type: "staff" } }
    assert_response :created
    assert EventStaffAssignment.exists?(event: @event, user: core_users(:attendee), type: "staff")
  end

  test "outsider cannot create a staff assignment" do
    post "/events/#{@event.id}/event_staff_assignments",
         headers: @attendee_headers, as: :json,
         params: { event_staff_assignment: { user_id: core_users(:attendee).id,
                   organization_id: @event.organization_id, type: "staff" } }
    assert_response :forbidden
  end

  test "owner can suspend an assignment via member action" do
    assignment = Events::EventStaffAssignment.create!(event: @event,
      user: core_users(:attendee), organization: @event.organization,
      type: "staff", status: "active")
    post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/suspend",
         headers: @owner_headers, as: :json
    assert_response :success
    assert_equal "suspended", assignment.reload.status
  end

  test "owner can revoke and change_role" do
    assignment = Events::EventStaffAssignment.create!(event: @event,
      user: core_users(:attendee), organization: @event.organization,
      type: "staff", status: "active")
    post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/revoke",
         headers: @owner_headers, as: :json
    assert_response :success
    assert_equal "revoked", assignment.reload.status

    assignment2 = Events::EventStaffAssignment.create!(event: @event,
      user: core_users(:scanner), organization: @event.organization,
      type: "staff", status: "active")
    post "/events/#{@event.id}/event_staff_assignments/#{assignment2.id}/change_role",
         headers: @owner_headers, as: :json, params: { type: "scanner" }
    assert_response :success
    assert_equal "scanner", assignment2.reload.type
  end

  test "collaborator org membership alone grants no event access" do
    # Add a partner org as collaborator, then confirm its members are not auto-granted:
    post "/events/#{@event.id}/event_organizations",
         headers: @owner_headers, as: :json,
         params: { event_organization: { organization_id: organizations_organizations(:three).id,
                   type: "co_organizer", role: "collaborator", status: "active" } }
    assert_response :created
    # A member of org three who is NOT an assignee/staff gets nothing:
    refute Events::AuthorizationResolver.access_granted?(core_users(:org_three_member), @event)
  end
end
```

```ruby
# test/integration/events/event_organizations_test.rb
require "test_helper"

class EventOrganizationsTest < ActionDispatch::IntegrationTest
  def setup
    @event = events_events(:ready_listing)
    @owner_headers = owner_headers
  end

  test "owner can add a collaborator organization" do
    post "/events/#{@event.id}/event_organizations",
         headers: @owner_headers, as: :json,
         params: { event_organization: { organization_id: organizations_organizations(:three).id,
                   type: "promoter", role: "collaborator", status: "active" } }
    assert_response :created
    assert EventOrganization.exists?(event: @event, organization: organizations_organizations(:three))
  end

  test "cannot add a primary_owner role collaborator" do
    post "/events/#{@event.id}/event_organizations",
         headers: @owner_headers, as: :json,
         params: { event_organization: { organization_id: organizations_organizations(:three).id,
                   type: "promoter", role: "primary_owner", status: "active" } }
    assert_response :unprocessable_entity
  end
end
```

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/events/event_staff_assignments_test.rb test/integration/events/event_organizations_test.rb`
Expected: failures — routes, controllers, policy, serializer undefined.

- [ ] **Step 3: Implement the policy**

```ruby
# app/policies/events/event_staff_assignment_policy.rb
# frozen_string_literal: true

module Events
  class EventStaffAssignmentPolicy < Core::ApplicationPolicy
    def index?
      Events::AuthorizationResolver.access_granted?(user, record.event)
    end

    def show?
      Events::AuthorizationResolver.access_granted?(user, record.event)
    end

    def create?
      Events::AuthorizationResolver.can_assign?(user, record.event, record.type)
    end

    def update?
      Events::AuthorizationResolver.can_assign?(user, record.event, record.type)
    end

    def destroy?
      Events::AuthorizationResolver.can_assign?(user, record.event, record.type)
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")

        event_ids = Events::EventPolicy::Scope.new(user, Events::Event).resolve.pluck(:id)
        scope.where(event_id: event_ids)
      end
    end
  end
end
```

- [ ] **Step 4: Implement the serializer**

```ruby
# app/serializers/events/event_staff_assignment_serializer.rb
# frozen_string_literal: true

module Events
  class EventStaffAssignmentSerializer < ActiveModelSerializers::ModelSerializer
    type :event_staff_assignment

    attributes :id, :type, :status, :user_id, :organization_id, :event_id,
               :created_at, :updated_at
  end
end
```

- [ ] **Step 5: Implement the controllers**

```ruby
# app/controllers/events/event_organizations_controller.rb
# frozen_string_literal: true

module Events
  class EventOrganizationsController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::EventOrganization
    self.parent_class = Events::Event
    self.default_serializer = Events::EventOrganizationSerializer

    private

    def model_params
      params.require(:event_organization).permit(:organization_id, :type, :role, :status)
    end
  end
end
```

```ruby
# app/controllers/events/event_staff_assignments_controller.rb
# frozen_string_literal: true

module Events
  class EventStaffAssignmentsController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::CommandResponse

    self.model_class = Events::EventStaffAssignment
    self.parent_class = Events::Event
    self.default_serializer = Events::EventStaffAssignmentSerializer

    before_action :set_assignment, only: %i[show update destroy suspend revoke change_role]

    def create
      @parent = set_parent
      result = Events::StaffAssignments::Assign.call(
        event: @parent, actor: current_user,
        user: Core::User.find(staff_params[:user_id]),
        organization: @parent.organization,
        type: staff_params[:type]
      )
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer },
                            success_status: :created)
    end

    def suspend
      result = Events::StaffAssignments::Suspend.call(assignment: @assignment, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    def revoke
      result = Events::StaffAssignments::Revoke.call(assignment: @assignment, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    def change_role
      result = Events::StaffAssignments::ChangeRole.call(
        assignment: @assignment, actor: current_user, type: params[:type]
      )
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    private

    def set_assignment
      @assignment = @parent.event_staff_assignments.find(params[:id])
    end

    def set_parent
      @parent = Events::Event.find(params[:event_id])
    end

    def staff_params
      params.require(:event_staff_assignment).permit(:user_id, :type)
    end

    def model_params
      params.require(:event_staff_assignment).permit(:type, :status, :user_id, :organization_id)
    end
  end
end
```

- [ ] **Step 6: Refactor `Events::EventPolicy` to delegate to the resolver**

```ruby
# app/policies/events/event_policy.rb  (replace private helpers)
    private

    def owner_or_collaborator?(event)
      Events::AuthorizationResolver.organization_admin_or_owner?(user, event)
    end

    def manager_of?(event)
      Events::AuthorizationResolver.role_for(user, event) == :manager
    end

    def staff_of?(event)
      Events::AuthorizationResolver.role_for(user, event).in?(%i[staff scanner contractor])
    end
```

- [ ] **Step 7: Add routes**

```ruby
# config/routes.rb — inside the existing `resources :events, only: %i[index show create update] do … end` block:
  resources :event_organizations, only: %i[index show create update destroy]
  resources :event_staff_assignments, only: %i[index show create update destroy] do
    post :suspend, on: :member
    post :revoke, on: :member
    post :change_role, on: :member
  end
```

- [ ] **Step 8: Add locale keys (event.en.yml, append under `en.event`)**

```yaml
    event_organization:
      success:
        index: "Event collaborators retrieved successfully"
        show: "Event collaborator retrieved successfully"
        create: "Event collaborator added successfully"
        update: "Event collaborator updated successfully"
        destroy: "Event collaborator removed successfully"
      errors:
        create: "Failed to add event collaborator"
        update: "Failed to update event collaborator"
        destroy: "Failed to remove event collaborator"
    event_staff_assignment:
      success:
        index: "Event staff retrieved successfully"
        show: "Event staff member retrieved successfully"
        create: "Staff assigned successfully"
        update: "Staff updated successfully"
        destroy: "Staff removed successfully"
      errors:
        create: "Failed to assign staff"
        update: "Failed to update staff"
        destroy: "Failed to remove staff"
```

- [ ] **Step 9: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/integration/events/event_staff_assignments_test.rb test/integration/events/event_organizations_test.rb`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add app/policies/events/event_staff_assignment_policy.rb \
  app/serializers/events/event_staff_assignment_serializer.rb \
  app/controllers/events/event_organizations_controller.rb \
  app/controllers/events/event_staff_assignments_controller.rb \
  app/policies/events/event_policy.rb config/routes.rb config/locales/events/event.en.yml \
  test/integration/events/event_staff_assignments_test.rb test/integration/events/event_organizations_test.rb
git commit -m "feat(events): add collaborator and staff assignment controllers, policy, serializer"
```

---

## Task 4: Fixtures + full suite + Postman

**Files:**
- Create: `test/fixtures/events_event_organizations.yml`
- Create: `test/fixtures/events_event_staff_assignments.yml`
- Modify: `postman/Digis API_collection.json`

- [ ] **Step 1: Add fixtures**

```yaml
# test/fixtures/events_event_organizations.yml
# frozen_string_literal: true

ready_promoter:
  event_id: 019e5f69-d002-7000-8000-000000000002
  organization_id: 019e5f69-db0a-709f-b748-fd8afb65216f
  type: promoter
  role: collaborator
  status: active
```

```yaml
# test/fixtures/events_event_staff_assignments.yml
# frozen_string_literal: true

ready_manager:
  event_id: 019e5f69-d002-7000-8000-000000000002
  user_id: 019e5f69-db1c-77b6-be88-3afbf8b65410
  organization_id: 019e5f69-db0a-709f-b748-fd8afb65216f
  type: manager
  status: active
```

(Add the referenced fixture orgs/users — `organizations_organizations(:three)`, `core_users(:org_three_member)`, `core_users(:scanner)`, `core_users(:staff)` — to their respective fixtures if absent. Reuse existing `core_users(:attendee)`, `core_users(:organizer_owner)`, `core_users(:super_admin)`, `core_users(:admin)`.)

- [ ] **Step 2: Run the full events test surface**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/events test/services/events test/integration/events`
Expected: 0 failures, 0 errors.

- [ ] **Step 3: Run RuboCop + Brakeman**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop app/services/events app/controllers/events app/policies/events && PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman --no-pager`
Expected: 0 offenses, 0 warnings.

- [ ] **Step 4: Update Postman collection**

Add to the `Events` folder:
- **Event Organizations**: `List` (GET `/events/:id/event_organizations`), `Get` (GET `/events/:id/event_organizations/:id`), `Create` (POST `/events/:id/event_organizations`, body `{ "event_organization": { "organization_id": "{{orgId}}", "type": "promoter", "role": "collaborator", "status": "active" } }`), `Update` (PATCH), `Delete` (DELETE).
- **Event Staff Assignments**: `List` (GET `/events/:id/event_staff_assignments`), `Get` (GET `/events/:id/event_staff_assignments/:id`), `Create` (POST, body `{ "event_staff_assignment": { "user_id": "{{userId}}", "type": "staff" } }`), `Update` (PATCH), `Delete` (DELETE), `Suspend` (POST `/events/:id/event_staff_assignments/:id/suspend`), `Revoke` (POST `…/revoke`), `Change Role` (POST `…/change_role`, body `{ "type": "scanner" }`).

- [ ] **Step 5: Validate Postman JSON**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails runner 'require "json"; JSON.parse(File.read("postman/Digis API_collection.json")); puts "OK"'`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/events_event_organizations.yml \
  test/fixtures/events_event_staff_assignments.yml postman/Digis API_collection.json
git commit -m "test(events): add staff/collaborator fixtures and Postman requests"
```

---

## Phase acceptance (Task 3 slice)

- Owners/admins access events without any assignment.
- Staff/scanner/contractor users require an **active** `EventStaffAssignment`; suspended/revoked/expired fail immediately.
- A collaborator `EventOrganization` record grants its org's members **no** event access by itself.
- Only owner/admin/manager may assign; managers may assign staff/scanner only.
- All staff transitions write a synchronous audit row and return `Core::BaseService::Result`.

Run the complete repository gate before declaring done:

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```
