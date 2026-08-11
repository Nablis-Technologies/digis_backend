# frozen_string_literal: true

module Commercial
  # Applies one immutable fee version to an organization-wide or event-scoped target.
  class Assignment < Commercial::ApplicationRecord
    self.table_name = "commercial_assignments"

    ASSIGNMENT_TYPES = %w[program platform_grant mutual_agreement].freeze
    STATUSES = %w[draft pending_acceptance pending_approval scheduled active expired terminated].freeze
    RISK_LEVELS = %w[low medium high].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :event, class_name: "Events::Event", optional: true
    belongs_to :fee_schedule_version,
               class_name: "Commercial::FeeScheduleVersion",
               inverse_of: :assignments
    belongs_to :program,
               class_name: "Commercial::Program",
               optional: true,
               inverse_of: :assignments
    belongs_to :legal_acceptance,
               class_name: "Legal::LegalAcceptance",
               optional: true
    belongs_to :created_by, class_name: "Core::User"
    belongs_to :approved_by, class_name: "Core::User", optional: true
    belongs_to :activated_by, class_name: "Core::User", optional: true
    belongs_to :terminated_by, class_name: "Core::User", optional: true
    belongs_to :external_accepted_by,
               class_name: "Core::User",
               optional: true

    has_many :simulations,
             class_name: "Commercial::Simulation",
             inverse_of: :assignment,
             dependent: :restrict_with_exception
    has_many :subsidy_budgets,
             class_name: "Commercial::SubsidyBudget",
             inverse_of: :assignment,
             dependent: :restrict_with_exception

    before_validation :normalize_external_reference

    validates :organization, presence: true
    validates :fee_schedule_version, presence: true
    validates :assignment_type, presence: true, inclusion: { in: ASSIGNMENT_TYPES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :reason, presence: true
    validates :effective_from, presence: true
    validates :risk_level, presence: true, inclusion: { in: RISK_LEVELS }
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :external_reference, length: { maximum: 255 }, allow_nil: true
    validates :baseline_resolution_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true

    validate :event_belongs_to_organization
    validate :effective_interval
    validate :program_matches_version
    validate :platform_grant_has_baseline
    validate :mutual_agreement_has_evidence_for_authoritative_status
    validate :external_acceptance_metadata
    validate :active_metadata
    validate :terminated_metadata
    validate :legal_acceptance_matches_version

    scope :active_at, lambda { |at|
      where(status: %w[scheduled active])
        .where("effective_from <= ?", at)
        .where("effective_until IS NULL OR effective_until > ?", at)
    }
    scope :for_organization, ->(organization_id) { where(organization_id:) }
    scope :for_event, ->(event_id) { where(event_id:) }

    def platform_grant?
      assignment_type == "platform_grant"
    end

    def mutual_agreement?
      assignment_type == "mutual_agreement"
    end

    def program_assignment?
      assignment_type == "program"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id organization_id event_id fee_schedule_version_id program_id assignment_type
        status reason external_reference legal_acceptance_id effective_from effective_until
        risk_level created_by_id approved_by_id activated_by_id terminated_by_id
        external_accepted_by_id baseline_resolution_digest lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[
        organization event fee_schedule_version program legal_acceptance created_by approved_by
        activated_by terminated_by external_accepted_by simulations subsidy_budgets
      ]
    end

    private

    def normalize_external_reference
      self.external_reference = external_reference.to_s.strip.presence
    end

    def event_belongs_to_organization
      return if event_id.blank? || organization_id.blank?
      return if Events::Event.where(id: event_id, organization_id: organization_id).exists?

      errors.add(:event, I18n.t("commercial.assignments.errors.event_organization_mismatch"))
    end

    def effective_interval
      return if effective_until.blank? || effective_from.blank? || effective_until > effective_from

      errors.add(:effective_until, I18n.t("commercial.assignments.errors.effective_interval"))
    end

    def program_matches_version
      if program_assignment? && program.blank?
        errors.add(:program, I18n.t("commercial.assignments.errors.program_required"))
        return
      end
      return if program.blank? || fee_schedule_version.blank?
      return if program.fee_schedule_id == fee_schedule_version.fee_schedule_id

      errors.add(:fee_schedule_version, I18n.t("commercial.assignments.errors.program_version_mismatch"))
    end

    def platform_grant_has_baseline
      return unless platform_grant?
      return if baseline_resolution_digest.present?

      errors.add(:baseline_resolution_digest, I18n.t("commercial.assignments.errors.baseline_required"))
    end

    def mutual_agreement_has_evidence_for_authoritative_status
      return unless mutual_agreement? && %w[scheduled active].include?(status)
      return if legal_acceptance_id.present? || external_reference.present?

      errors.add(:base, I18n.t("commercial.assignments.errors.mutual_evidence_required"))
    end

    def external_acceptance_metadata
      return if external_reference.blank?
      return if external_accepted_by_id.present? && external_accepted_at.present?

      errors.add(:external_reference, I18n.t("commercial.assignments.errors.external_metadata_required"))
    end

    def active_metadata
      return unless status == "active"
      return if activated_by_id.present? && activated_at.present?

      errors.add(:activated_by, I18n.t("commercial.assignments.errors.activated_metadata"))
    end

    def terminated_metadata
      return unless status == "terminated"
      return if terminated_by_id.present? && terminated_at.present?

      errors.add(:terminated_by, I18n.t("commercial.assignments.errors.terminated_metadata"))
    end

    def legal_acceptance_matches_version
      return if legal_acceptance.blank?

      unless legal_acceptance.subject_type == "commercial_assignment" && legal_acceptance.subject_id == id
        errors.add(:legal_acceptance, I18n.t("commercial.assignments.errors.legal_subject_mismatch"))
        return
      end

      expected_id = fee_schedule_version&.legal_document_version_id
      return if expected_id.present? && legal_acceptance.legal_document_version_id == expected_id

      errors.add(:legal_acceptance, I18n.t("commercial.assignments.errors.legal_version_mismatch"))
    end
  end
end
