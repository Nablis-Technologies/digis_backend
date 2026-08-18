# frozen_string_literal: true

module Commercial
  class FeeScheduleVersionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :fee_schedule_id, :supersedes_version_id, :version, :status,
      :definition_digest, :legal_document_version_id, :acceptance_policy,
      :grandfather_until, :effective_from, :effective_until, :submitted_by_id,
      :submitted_at, :approved_by_id, :approved_at, :activated_by_id,
      :activated_at, :terminated_by_id, :terminated_at, :lock_version,
      :created_at, :updated_at

    has_many :fee_components, serializer: Commercial::FeeComponentSerializer
    has_many :assignments, serializer: Commercial::AssignmentSerializer
    has_many :simulations, serializer: Commercial::SimulationSerializer
  end
end
