# frozen_string_literal: true

module Commercial
  class FeeScheduleSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :name, :code, :schedule_type, :created_by_id, :created_at, :updated_at

    has_many :fee_schedule_versions, serializer: Commercial::FeeScheduleVersionSerializer
  end
end
