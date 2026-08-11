# frozen_string_literal: true

require_relative "fee_definition_test_helpers"
require_relative "governance_test_helpers"

module Commercial
  # Builds a complete automatic first-event program and published events for
  # entitlement tests without relying on application seed data.
  module EntitlementTestHelpers
    include Commercial::GovernanceTestHelpers

    def create_first_event_program(organization:, enrollment_mode: "automatic", active: true,
      starts_at: 2.days.ago, ends_at: 2.days.from_now)
      version = create_active_version(
        code: "first_event_#{SecureRandom.hex(5)}",
        attributes: { schedule_type: "program", effective_from: starts_at }
      )
      program = Commercial::Program.create!(
        fee_schedule: version.fee_schedule,
        program_type: "first_monetized_event",
        enrollment_mode:,
        starts_at:,
        ends_at:,
        active:
      )
      assignment = Commercial::Assignment.create!(
        organization:,
        fee_schedule_version: version,
        program:,
        assignment_type: "program",
        status: "active",
        reason: "First-event launch benefit",
        effective_from: starts_at,
        risk_level: "low",
        created_by: core_users(:super_admin),
        activated_by: core_users(:super_admin),
        activated_at: starts_at
      )
      [ program, assignment ]
    end

    def create_published_event(organization:, published_at: Time.current, title: nil)
      Events::Event.create!(
        organization:,
        created_by: core_users(:super_admin),
        slug: "entitlement-#{SecureRandom.hex(6)}",
        title: title || "Entitlement event #{SecureRandom.hex(4)}",
        visibility: "public",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        status: "published",
        published_at:
      )
    end

    def delete_first_event_program!(program, assignment)
      entitlement_ids = Commercial::ProgramEntitlement.where(program_id: program.id).pluck(:id)
      Core::AuditLog.where(auditable_type: "Commercial::ProgramEntitlement", auditable_id: entitlement_ids).delete_all
      Commercial::ProgramEntitlement.where(id: entitlement_ids).delete_all
      Commercial::Assignment.where(id: assignment.id).delete_all
      version = program.fee_schedule.fee_schedule_versions.first
      # Test-only definitions are activated so the real resolver sees an
      # authoritative version. Move the version back to draft before cleanup;
      # production immutable definitions must never be deleted or rewritten.
      version.update_column(:status, "draft")
      version.fee_components.each do |component|
        Commercial::FeeAmount.where(fee_component_id: component.id).delete_all
        Commercial::FeeTier.where(fee_component_id: component.id).delete_all
      end
      Commercial::FeeComponent.where(fee_schedule_version_id: version.id).delete_all
      # The existing database trigger intentionally makes every fee-version
      # delete a no-op, including draft rows. Leave that immutable definition
      # evidence in place after removing its mutable child components.
      program.delete
    end
  end
end
