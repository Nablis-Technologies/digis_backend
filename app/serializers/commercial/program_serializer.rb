# frozen_string_literal: true

module Commercial
  class ProgramSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :fee_schedule_id, :program_type, :enrollment_mode, :starts_at,
      :ends_at, :per_organization_use_limit, :active, :created_at, :updated_at
  end
end
