# frozen_string_literal: true

module Ticketing
  # A versioned registration schema. Drafts remain editable; published and
  # retired versions are immutable so submissions always retain their exact
  # questionnaire definition.
  class RegistrationFormVersion < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_form_versions"

    STATUSES = %w[draft published retired].freeze

    belongs_to :registration_form, class_name: "Ticketing::RegistrationForm"
    belongs_to :published_by, class_name: "Core::User", optional: true

    has_many :questions,
             class_name: "Ticketing::RegistrationQuestion",
             dependent: :restrict_with_exception
    has_many :submissions,
             class_name: "Ticketing::RegistrationFormSubmission",
             dependent: :restrict_with_exception

    validates :version, presence: true,
                        numericality: { only_integer: true, greater_than: 0 }
    validates :status, presence: true, inclusion: { in: STATUSES }

    validate :publish_metadata
    validate :version_is_monotonic
    validate :published_or_retired_immutable
    before_destroy :prevent_destroy_if_immutable

    scope :draft, -> { where(status: "draft") }
    scope :published, -> { where(status: "published") }
    scope :retired, -> { where(status: "retired") }

    def published?
      status == "published"
    end

    def retired?
      status == "retired"
    end

    def immutable?
      state = persisted? ? status_in_database : status
      %w[published retired].include?(state)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id registration_form_id version status published_by_id published_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration_form published_by questions submissions]
    end

    private

    def publish_metadata
      if status == "draft"
        errors.add(:published_by_id, :invalid) if published_by_id.present?
        errors.add(:published_at, :invalid) if published_at.present?
      elsif published_by_id.blank? || published_at.blank?
        errors.add(:published_by_id, :blank) if published_by_id.blank?
        errors.add(:published_at, :blank) if published_at.blank?
      end
    end

    def version_is_monotonic
      return if registration_form.blank? || version.blank?
      return if persisted? && (changes.keys - [ "status" ]).empty?

      relation = self.class.where(registration_form_id: registration_form_id).where.not(id: id)
      previous_version = relation.maximum(:version)
      return if previous_version.blank? || version > previous_version

      errors.add(:version, :greater_than, count: previous_version)
    end

    def published_or_retired_immutable
      return unless persisted? && %w[published retired].include?(status_in_database)

      changed_columns = changes.keys - [ "status" ]
      errors.add(:base, :immutable) if changed_columns.any?

      return unless status_in_database == "retired" && status != "retired"

      errors.add(:status, :immutable)
    end

    def prevent_destroy_if_immutable
      return unless immutable?

      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_registration_form_version")
    end
  end
end
