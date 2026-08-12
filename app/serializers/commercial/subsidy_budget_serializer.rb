# frozen_string_literal: true

module Commercial
  class SubsidyBudgetSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :assignment_id, :program_id, :fee_component_id, :currency,
      :limit_minor, :reserved_minor, :consumed_minor, :lock_version,
      :created_at, :updated_at, :remaining_minor

    def remaining_minor
      object.remaining_minor
    end
  end
end
