# frozen_string_literal: true

module Commercial
  # Append-only maker/checker evidence for a version or assignment decision.
  # The target allowlist prevents this polymorphic record from becoming a
  # generic approval mechanism for unrelated domains.
  class Approval < Commercial::ApplicationRecord
    self.table_name = "commercial_approvals"

    TARGET_TYPES = %w[Commercial::FeeScheduleVersion Commercial::Assignment].freeze
    DECISIONS = %w[approved rejected].freeze

    belongs_to :target, polymorphic: true
    belongs_to :actor, class_name: "Core::User"

    validates :target_type, presence: true, inclusion: { in: TARGET_TYPES }
    validates :decision, presence: true, inclusion: { in: DECISIONS }
    validates :reason, presence: true
    validates :definition_digest, :idempotency_key_digest, :request_fingerprint,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :decided_at, presence: true
    before_update :prevent_append_only_mutation
    before_destroy :prevent_append_only_destroy

    def self.ransackable_attributes(_auth_object = nil)
      %w[id target_type target_id decision definition_digest actor_id decided_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[target actor]
    end

    private

    def prevent_append_only_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.governance.errors.append_only_approval")
    end

    def prevent_append_only_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.governance.errors.append_only_approval")
    end
  end
end
