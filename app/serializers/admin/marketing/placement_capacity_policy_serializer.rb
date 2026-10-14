# frozen_string_literal: true

module Admin
  module Marketing
    # Safe operator projection; idempotency and request digests never leave the
    # command/audit boundary.
    class PlacementCapacityPolicySerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :surface, :version, :max_concurrent, :status, :effective_from, :effective_until,
        :created_by_id, :activated_by_id, :retired_by_id, :activated_at, :retired_at, :created_at, :updated_at
    end
  end
end
