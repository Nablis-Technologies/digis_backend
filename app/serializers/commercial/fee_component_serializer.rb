# frozen_string_literal: true

module Commercial
  class FeeComponentSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :fee_schedule_version_id, :component_type, :calculation_type,
      :charged_to, :organizer_payer_choice, :funded_by, :basis_type, :rate_bps,
      :refund_policy, :offset_component_type, :event_product_id, :product_type,
      :sale_context, :provider, :payment_method, :sales_channel, :currency,
      :label, :created_at, :updated_at

    has_many :fee_amounts, serializer: Commercial::FeeAmountSerializer
    has_many :fee_tiers, serializer: Commercial::FeeTierSerializer
  end
end
