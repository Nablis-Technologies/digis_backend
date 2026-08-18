# frozen_string_literal: true

module Commercial
  class AssignmentSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :event_id, :fee_schedule_version_id,
      :program_id, :assignment_type, :status, :reason, :external_reference,
      :legal_acceptance_id, :effective_from, :effective_until, :risk_level,
      :created_by_id, :approved_by_id, :approved_at, :activated_by_id,
      :activated_at, :terminated_by_id, :terminated_at, :external_accepted_by_id,
      :external_accepted_at, :baseline_resolution_digest, :lock_version,
      :created_at, :updated_at
  end
end
