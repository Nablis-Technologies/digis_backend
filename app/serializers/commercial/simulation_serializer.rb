# frozen_string_literal: true

module Commercial
  class SimulationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :fee_schedule_version_id, :assignment_id, :definition_digest,
      :scenario_digest, :normalized_outputs, :warnings, :passed, :run_by_id,
      :run_at, :created_at, :updated_at
  end
end
