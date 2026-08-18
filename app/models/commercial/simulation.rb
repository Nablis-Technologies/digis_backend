# frozen_string_literal: true

module Commercial
  # Immutable evidence that a fee definition was evaluated against one
  # normalized scenario. The definition and scenario digests are the binding
  # contract; the raw scenario is intentionally never stored.
  class Simulation < Commercial::ApplicationRecord
    self.table_name = "commercial_simulations"

    belongs_to :fee_schedule_version,
               class_name: "Commercial::FeeScheduleVersion",
               inverse_of: :simulations
    belongs_to :assignment,
               class_name: "Commercial::Assignment",
               optional: true,
               inverse_of: :simulations
    belongs_to :run_by, class_name: "Core::User"

    validates :definition_digest, :scenario_digest, :idempotency_key_digest,
              :request_fingerprint,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :run_at, presence: true
    validates :passed, inclusion: { in: [ true, false ] }
    validate :assignment_matches_version
    before_update :prevent_evidence_mutation
    before_destroy :prevent_evidence_destroy

    scope :passing, -> { where(passed: true) }
    scope :current_for, lambda { |version, digest|
      where(fee_schedule_version: version, definition_digest: digest).order(run_at: :desc)
    }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id fee_schedule_version_id assignment_id definition_digest scenario_digest passed run_by_id run_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_schedule_version assignment run_by]
    end

    private

    def assignment_matches_version
      return if assignment.blank? || assignment.fee_schedule_version_id == fee_schedule_version_id

      errors.add(:assignment, I18n.t("commercial.governance.errors.assignment_version_mismatch"))
    end

    def prevent_evidence_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.governance.errors.immutable_simulation")
    end

    def prevent_evidence_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.governance.errors.immutable_simulation")
    end
  end
end
