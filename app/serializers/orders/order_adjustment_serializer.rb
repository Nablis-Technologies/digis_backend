# frozen_string_literal: true

module Orders
  # Exposes only the buyer-facing adjustment line. Commercial source IDs,
  # calculation evidence, and organizer-charged adjustments stay private.
  class OrderAdjustmentSerializer < ActiveModel::Serializer
    attributes :id, :type, :label, :amount_minor, :currency, :refund_policy
  end
end
