# frozen_string_literal: true

module Commercial
  # Shared setup for Task 5 tests. It builds the minimum complete definition
  # needed by the real resolver, so lifecycle tests cannot accidentally prove
  # governance against a partial fee schedule.
  module GovernanceTestHelpers
    include Commercial::FeeDefinitionTestHelpers

    def create_simulatable_version(code:, attributes: {}, **keyword_attributes)
      attributes = attributes.merge(keyword_attributes)
      schedule = create_schedule(code:, schedule_type: attributes.delete(:schedule_type) || "custom")
      version = create_version(schedule, attributes)

      populate_simulatable_version(version)
    end

    def populate_simulatable_version(version)
      create_component(version)
      buyer_fee = build_component(
        version,
        component_type: "buyer_service_fee",
        calculation_type: "fixed",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: nil,
        rate_bps: nil,
        label: "Buyer service fee"
      )
      buyer_fee.save!
      create_amount(buyer_fee, fixed_amount_minor: 25)

      processing = build_component(
        version,
        component_type: "processing_cost_recovery",
        calculation_type: "explicit_zero",
        charged_to: "organizer",
        funded_by: "organizer",
        basis_type: nil,
        rate_bps: nil,
        label: "Processing cost recovery"
      )
      processing.save!

      sync_definition_digest(version)
      version
    end

    def authorize(actor, permission_code)
      permission = Core::Permission.find_by!(code: permission_code)
      role = actor.roles.first
      Core::RolePermission.find_or_create_by!(role:, permission:)
      actor.clear_permission_cache!
      actor
    end

    def run_passing_simulation(version:, idempotency_key:, assignment: nil, scenario: nil)
      Commercial::Simulations::Run.call(
        version:, assignment:, actor: core_users(:super_admin),
        scenario: scenario || { resolution_context: simulation_scenario },
        idempotency_key:
      )
    end

    def create_published_legal_version(document_type: "organizer_fee_schedule")
      document = Legal::LegalDocument.create!(
        document_type:,
        internal_name: "Governance terms #{SecureRandom.hex(4)}",
        jurisdiction_code: "ET-#{SecureRandom.hex(3).upcase}",
        locale: "en",
        created_by: core_users(:super_admin)
      )
      document.versions.create!(
        version: 1,
        title: "Organizer terms",
        body: "Published organizer terms",
        content_sha256: Legal::LegalDocumentVersion.content_sha256_for(
          title: "Organizer terms", body: "Published organizer terms"
        ),
        status: "published",
        published_by: core_users(:super_admin),
        published_at: Time.current,
        created_by: core_users(:super_admin)
      )
    end

    def simulation_scenario(organization: organizations_organizations(:one), quoted_at: Time.current)
      {
        organization_id: organization.id,
        currency: "ETB",
        settlement_currency: "ETB",
        sale_context: "primary",
        quoted_at:,
        eligible_order_subtotal_minor: 1_000,
        item_face_value_minor: 1_000
      }
    end

    def create_active_version(code:, version_number: 1, effective_from: 2.days.ago, attributes: {})
      version = create_simulatable_version(
        code:,
        attributes: attributes.merge(version: version_number, effective_from:, status: "draft")
      )
      version.update!(
        status: "active",
        activated_by: core_users(:super_admin),
        activated_at: effective_from,
        submitted_by: core_users(:super_admin),
        submitted_at: effective_from
      )
      version
    end
  end
end
