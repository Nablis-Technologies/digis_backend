# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AttendeeExportPolicyTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @other_event = events_events(:draft_concert)
      @requester = core_users(:attendee)
      @ticket_type = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Policy export ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
      @registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: @requester,
        created_by: @requester,
        source: "self_service",
        identity_digest: "f" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "confirmed",
        submitted_at: Time.current
      )
      @form = Ticketing::RegistrationForm.create!(event: @event, name: "Policy questions", active: true)
      @version = @form.versions.create!(version: 1, status: "draft")
      @dietary_question = @version.questions.create!(
        key: "meal",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "dietary",
        label: "Meal",
        position: 0,
        options: [],
        validation_rules: {}
      )
      @accessibility_question = @version.questions.create!(
        key: "mobility",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "accessibility",
        label: "Mobility",
        position: 1,
        options: [],
        validation_rules: {}
      )
      @version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
      @registration.form_submissions.create!(
        registration_form_version: @version,
        submitted_by_user: @requester,
        submitted_at: Time.current
      )
    end

    test "requires request permission in addition to event manageability" do
      make_admin(@requester)
      export = build_export(requested_by: @requester)

      grant(@requester, "attendee_export.contact")
      assert_not policy_for(@requester, export).create?

      grant(@requester, "attendee_export.request")
      assert policy_for(@requester, export).create?
    end

    test "allows primary owners and admins with the request permission" do
      make_admin(@requester)
      grant(@requester, "attendee_export.request")
      assert policy_for(@requester, build_export).create?

      admin = core_users(:support)
      Organizations::Membership.create!(
        organization: @event.organization,
        user: admin,
        role: "admin",
        status: "active"
      )
      grant(admin, "attendee_export.request")
      assert policy_for(admin, build_export(requested_by: admin)).create?
    end

    test "allows an owner of an active co-organizer organization" do
      owner = core_users(:support)
      ensure_membership(owner, organizations_organizations(:three), role: "owner")
      Events::EventOrganization.create!(
        event: @event,
        organization: organizations_organizations(:three),
        type: "co_organizer",
        role: "collaborator",
        status: "active"
      )
      grant(owner, "attendee_export.request")

      assert policy_for(owner, build_export(requested_by: owner)).create?
    end

    test "allows an active event manager but not an inactive manager" do
      manager = core_users(:support)
      assignment = Events::EventStaffAssignment.create!(
        event: @event,
        user: manager,
        organization: @event.organization,
        role: "manager",
        status: "active"
      )
      grant(manager, "attendee_export.contact")
      assert_not policy_for(manager, build_export(requested_by: manager)).create?

      grant(manager, "attendee_export.request")
      assert policy_for(manager, build_export(requested_by: manager)).create?

      assignment.update!(status: "suspended")
      assert_not policy_for(manager, build_export(requested_by: manager)).create?
    end

    test "platform administrators can manage any event" do
      admin = core_users(:super_admin)
      export = build_export(event: @other_event, requested_by: admin)

      assert policy_for(admin, export).create?
      assert policy_for(admin, export).show?
      assert policy_for(admin, export).download_authorizations?
    end

    test "staff assignment never receives export access" do
      actor = core_users(:support)
      create_assignment(actor, role: "staff")
      grant(actor, "attendee_export.request")

      assert_not policy_for(actor, build_export(requested_by: actor)).create?
    end

    test "scanner assignment never receives export access" do
      actor = core_users(:attendee)
      create_assignment(actor, role: "scanner")
      grant(actor, "attendee_export.request")

      assert_not policy_for(actor, build_export(requested_by: actor)).create?
    end

    test "denies an otherwise permitted actor for an unrelated event" do
      make_admin(@requester)
      grant(@requester, "attendee_export.request")

      export = build_export(event: @other_event, requested_by: @requester)
      assert_not policy_for(@requester, export).create?
    end

    test "restricts show and download metadata to the requester or platform administrator" do
      make_admin(@requester)
      grant(@requester, "attendee_export.request")
      export = build_export(requested_by: @requester)
      assert policy_for(@requester, export).show?
      assert policy_for(@requester, export).download_authorizations?

      manager = core_users(:support)
      Events::EventStaffAssignment.create!(
        event: @event,
        user: manager,
        organization: @event.organization,
        role: "manager",
        status: "active"
      )
      grant(manager, "attendee_export.request")
      assert_not policy_for(manager, export).show?
      assert_not policy_for(manager, export).download_authorizations?

      assert policy_for(core_users(:super_admin), export).show?
      assert policy_for(core_users(:super_admin), export).download_authorizations?
    end

    test "rechecks current field permissions for show and download" do
      make_admin(@requester)
      export = build_export(
        requested_by: @requester,
        field_keys: [ "registration_user_email" ]
      )
      grant(@requester, "attendee_export.request", "attendee_export.contact")
      assert policy_for(@requester, export).show?
      assert policy_for(@requester, export).download_authorizations?

      grant(@requester, "attendee_export.request")
      assert_not policy_for(@requester, export).show?
      assert_not policy_for(@requester, export).download_authorizations?
    end

    test "does not expose an expired tombstone to a requester without current field authorization" do
      make_admin(@requester)
      grant(@requester, "attendee_export.request")
      export = build_export(
        requested_by: @requester,
        status: "expired",
        field_keys: nil,
        filters: nil,
        expired_at: Time.current
      )

      assert_not policy_for(@requester, export).show?
      assert policy_for(core_users(:super_admin), export).show?
    end

    test "rechecks current event manageability for requester show and download" do
      manager = core_users(:support)
      assignment = create_assignment(manager, role: "manager")
      grant(manager, "attendee_export.request")
      export = build_export(requested_by: manager)

      assert policy_for(manager, export).show?
      assert policy_for(manager, export).download_authorizations?

      assignment.update!(status: "suspended")
      assert_not policy_for(manager, export).show?
      assert_not policy_for(manager, export).download_authorizations?
    end

    test "does not let a business reason grant a missing field permission" do
      make_admin(@requester)
      export = build_export(
        requested_by: @requester,
        field_keys: [ "registration_user_email" ],
        reason_code: "dietary_accommodation"
      )
      grant(@requester, "attendee_export.request")

      assert_not policy_for(@requester, export).create?
    end

    test "requires the request permission as a base for every field and action" do
      make_admin(@requester)
      export = build_export(
        requested_by: @requester,
        field_keys: [ "registration_user_email" ]
      )
      grant(@requester, "attendee_export.contact")

      assert_not policy_for(@requester, export).create?
      assert_not policy_for(@requester, export).show?
      assert_not policy_for(@requester, export).download_authorizations?
    end

    test "does not let a core admin bypass the request permission for an expired tombstone" do
      admin = core_users(:core_admin)
      export = build_export(
        requested_by: @requester,
        status: "expired",
        field_keys: nil,
        filters: nil,
        expired_at: Time.current
      )

      assert_not policy_for(admin, export).show?
    end

    test "accepts only the exact reason allowlist and bounded filter contract" do
      make_admin(@requester)
      grant(@requester, "attendee_export.request")

      %w[
        event_operations attendee_communication dietary_accommodation
        accessibility_accommodation customer_support legal_compliance
      ].each do |reason_code|
        assert policy_for(@requester, build_export(reason_code:)).create?, reason_code
      end

      invalid_reason = build_export(reason_code: "attendee_export")
      assert_not policy_for(@requester, invalid_reason).create?

      oversized_filter = build_export(
        filters: { "access_event_date_ids" => Array.new(101) { SecureRandom.uuid } }
      )
      assert_not policy_for(@requester, oversized_filter).create?
    end

    test "requires contact, dietary, and accessibility permissions separately from request permission" do
      make_admin(@requester)
      grant(@requester, "attendee_export.request")

      contact = build_export(field_keys: [ "registration_user_phone" ])
      dietary = build_export(field_keys: [ question_selector(@dietary_question) ])
      accessibility = build_export(field_keys: [ question_selector(@accessibility_question) ])

      assert_not policy_for(@requester, contact).create?
      assert_not policy_for(@requester, dietary).create?
      assert_not policy_for(@requester, accessibility).create?

      grant(@requester, "attendee_export.request", "attendee_export.contact")
      assert policy_for(@requester, contact).create?
      grant(
        @requester,
        "attendee_export.request",
        "attendee_export.dietary",
        "attendee_export.accessibility"
      )
      assert policy_for(@requester, dietary).create?
      assert policy_for(@requester, accessibility).create?
    end

    private

    def build_export(
      event: @event,
      requested_by: @requester,
      field_keys: [ "registration_id" ],
      row_mode: "registration",
      filters: {},
      reason_code: "event_operations",
      status: "pending",
      expired_at: nil
    )
      Ticketing::AttendeeExport.new(
        event:,
        requested_by:,
        status:,
        row_mode:,
        format_version: "csv_v1",
        field_keys:,
        filters:,
        reason_code:,
        data_cutoff_at: Time.current,
        expires_at: 1.hour.from_now,
        expired_at:,
        field_set_digest: "a" * 64,
        filter_digest: "b" * 64,
        idempotency_key_digest: "c" * 64,
        request_fingerprint: "d" * 64,
        digest_key_version: "v1",
        attempt_count: 0
      )
    end

    def policy_for(actor, export)
      Ticketing::AttendeeExportPolicy.new(actor, export)
    end

    def make_admin(actor)
      Organizations::Membership.create!(
        organization: @event.organization,
        user: actor,
        role: "admin",
        status: "active"
      )
    end

    def ensure_membership(user, organization, role:)
      membership = Organizations::Membership.find_or_initialize_by(user:, organization:)
      membership.assign_attributes(role:, status: "active")
      membership.save!
    end

    def create_assignment(user, role:)
      Events::EventStaffAssignment.create!(
        event: @event,
        user:,
        organization: @event.organization,
        role:,
        status: "active"
      )
    end

    def grant(actor, *permissions)
      actor.stubs(:has_permission?).returns(false)
      permissions.each do |permission|
        actor.stubs(:has_permission?).with(permission).returns(true)
      end
    end

    def question_selector(question)
      "question:#{question.registration_form_version.registration_form_id}:#{question.key}"
    end
  end
end
