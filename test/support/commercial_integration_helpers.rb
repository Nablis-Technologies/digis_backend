# frozen_string_literal: true

module CommercialIntegrationHelpers
  def build_commercial_schedule(schedule_type: "custom", code: "custom_terms")
    Commercial::FeeSchedule.create!(
      name: "Custom terms",
      code:,
      schedule_type:,
      created_by: core_users(:super_admin)
    )
  end

  def build_commercial_version(schedule, effective_from: 1.hour.ago, status: "draft")
    version = schedule.fee_schedule_versions.create!(
      version: 1,
      status: "draft",
      definition_digest: "0" * 64,
      acceptance_policy: "none"
    )
    component = version.fee_components.create!(
      component_type: "buyer_service_fee",
      calculation_type: "percentage",
      charged_to: "buyer",
      funded_by: "buyer",
      basis_type: "item_face_value",
      rate_bps: 250,
      refund_policy: "nonrefundable",
      label: "Buyer service fee"
    )
    version.update!(definition_digest: Commercial::Definitions::Canonicalize.call(version:).value.digest)
    if status != "draft"
      version.update!(
        status:, effective_from:,
        activated_by: status == "active" ? core_users(:super_admin) : nil,
        activated_at: status == "active" ? Time.current : nil
      )
    end
    [ version, component ]
  end

  def build_event_product(event)
    Catalog::EventProduct.create!(
      event:,
      name: "General admission",
      type: "other",
      status: "draft",
      inventory_mode: "unlimited",
      min_per_order: 1,
      schedule_change_refund_policy: "full_or_partial"
    )
  end
end
