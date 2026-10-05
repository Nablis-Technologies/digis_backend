# frozen_string_literal: true

module Marketplace
  # Buyer/seller listing projection. Fee terms are policy metadata from the
  # immutable Commercial component; seller acquisition and cap snapshots are
  # filtered by ResaleListingPolicy for buyers.
  class ResaleListingSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :ticket_id, :ticket_type_id, :seller_user_id, :status,
               :asking_amount_minor, :currency, :seller_acquisition_product_value_minor,
               :cap_type_snapshot, :fixed_cap_minor_snapshot, :percentage_cap_bps_snapshot,
               :calculated_cap_minor, :resale_count_before, :max_completed_resales_snapshot,
               :resale_cutoff_at, :commercial_fee_component_id,
               :commercial_fee_schedule_version_id, :activated_at, :sold_at, :closed_at,
               :fee_terms, :created_at, :updated_at

    def fee_terms
      component = object.commercial_fee_component
      {
        calculation_type: component.calculation_type,
        refund_policy: component.refund_policy,
        rate_bps: component.rate_bps,
        currency: object.currency
      }.compact
    end
  end
end
