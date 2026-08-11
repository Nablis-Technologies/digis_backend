# frozen_string_literal: true

module Commercial
  class FeeScheduleVersion < Commercial::ApplicationRecord
    self.table_name = "commercial_fee_schedule_versions"

    STATUSES = %w[
      draft simulated pending_approval approved scheduled active superseded expired terminated
    ].freeze
    ACCEPTANCE_POLICIES = %w[none notice_only explicit].freeze
    IMMUTABLE_STATUSES = %w[approved scheduled active superseded expired terminated].freeze
    DEFINITION_ATTRIBUTES = %w[
      fee_schedule_id supersedes_version_id version definition_digest
      legal_document_version_id acceptance_policy grandfather_until
      effective_from effective_until
    ].freeze

    belongs_to :fee_schedule,
               class_name: "Commercial::FeeSchedule",
               inverse_of: :fee_schedule_versions
    belongs_to :supersedes_version,
               class_name: "Commercial::FeeScheduleVersion",
               optional: true,
               inverse_of: :superseding_versions
    belongs_to :legal_document_version,
               class_name: "Legal::LegalDocumentVersion",
               optional: true
    belongs_to :submitted_by, class_name: "Core::User", optional: true
    belongs_to :approved_by, class_name: "Core::User", optional: true
    belongs_to :activated_by, class_name: "Core::User", optional: true
    belongs_to :terminated_by, class_name: "Core::User", optional: true

    has_many :superseding_versions,
             class_name: "Commercial::FeeScheduleVersion",
             foreign_key: :supersedes_version_id,
             inverse_of: :supersedes_version,
             dependent: :restrict_with_exception
    has_many :fee_components,
             class_name: "Commercial::FeeComponent",
             inverse_of: :fee_schedule_version,
             dependent: :restrict_with_exception
    has_many :assignments,
             class_name: "Commercial::Assignment",
             inverse_of: :fee_schedule_version,
             dependent: :restrict_with_exception

    validates :fee_schedule, presence: true
    validates :version, presence: true,
              numericality: { only_integer: true, greater_than: 0 },
              uniqueness: { scope: :fee_schedule_id }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :definition_digest, presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :acceptance_policy, presence: true, inclusion: { in: ACCEPTANCE_POLICIES }
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    validate :same_schedule_supersession
    validate :effective_interval
    validate :authoritative_start
    validate :lifecycle_metadata
    validate :definition_immutable
    before_destroy :prevent_definition_destroy

    scope :draft, -> { where(status: "draft") }
    scope :approved, -> { where(status: "approved") }
    scope :authoritative, -> { where(status: %w[scheduled active]) }
    scope :active_at, lambda { |at|
      where(status: %w[scheduled active])
        .where("effective_from <= ?", at)
        .where("effective_until IS NULL OR effective_until > ?", at)
    }

    def authoritative?
      %w[scheduled active].include?(status)
    end

    def definition_immutable?
      IMMUTABLE_STATUSES.include?(status)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id fee_schedule_id version status definition_digest acceptance_policy
        effective_from effective_until created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_schedule supersedes_version legal_document_version fee_components assignments]
    end

    private

    def same_schedule_supersession
      return if supersedes_version.blank? || fee_schedule_id.blank?
      return if supersedes_version.fee_schedule_id == fee_schedule_id

      errors.add(:supersedes_version, I18n.t("commercial.definitions.errors.same_schedule"))
    end

    def effective_interval
      return if effective_from.blank? || effective_until.blank?
      return if effective_until > effective_from

      errors.add(:effective_until, I18n.t("commercial.definitions.errors.effective_interval"))
    end

    def authoritative_start
      return unless %w[scheduled active].include?(status)
      return if effective_from.present?

      errors.add(:effective_from, I18n.t("commercial.definitions.errors.effective_from_required"))
    end

    def lifecycle_metadata
      if status == "approved"
        add_pair_error(:approved_by, :approved_at, "approved_metadata")
      elsif status == "active"
        add_pair_error(:activated_by, :activated_at, "activated_metadata")
      elsif status == "terminated"
        add_pair_error(:terminated_by, :terminated_at, "terminated_metadata")
      end
    end

    def add_pair_error(actor_attribute, timestamp_attribute, message_key)
      return if public_send(actor_attribute).present? && public_send(timestamp_attribute).present?

      errors.add(actor_attribute, I18n.t("commercial.definitions.errors.#{message_key}"))
    end

    def definition_immutable
      return unless persisted? && IMMUTABLE_STATUSES.include?(status_in_database)
      return unless DEFINITION_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }

      errors.add(:base, I18n.t("commercial.definitions.errors.immutable"))
    end

    def prevent_definition_destroy
      return unless definition_immutable?

      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.definitions.errors.immutable")
    end
  end
end
