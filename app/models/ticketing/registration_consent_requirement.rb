# frozen_string_literal: true

module Ticketing
  # Immutable document/scope evidence required for one registration coordinate.
  # Only status, assignment, and append-only lineage may change after creation.
  class RegistrationConsentRequirement < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_consent_requirements"

    ACCEPTANCE_SCOPES = %w[buyer admission_slot].freeze
    STATUSES = %w[pending accepted withdrawn superseded].freeze
    REQUIRED_REASONS = %w[initial_submission reconsent].freeze

    belongs_to :registration, class_name: "Ticketing::Registration"
    belongs_to :consent_document_version, class_name: "Events::ConsentDocumentVersion"
    belongs_to :subject_user, class_name: "Core::User", optional: true
    belongs_to :supersedes_requirement,
               class_name: "Ticketing::RegistrationConsentRequirement",
               optional: true
    belongs_to :required_by, class_name: "Core::User", optional: true

    has_one :registration_consent,
            class_name: "Ticketing::RegistrationConsent",
            dependent: :restrict_with_exception
    has_one :superseding_requirement,
            class_name: "Ticketing::RegistrationConsentRequirement",
            foreign_key: :supersedes_requirement_id,
            dependent: :restrict_with_exception

    validates :required, inclusion: { in: [ true, false ] }
    validates :acceptance_scope, presence: true, inclusion: { in: ACCEPTANCE_SCOPES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :required_reason, presence: true, inclusion: { in: REQUIRED_REASONS }
    validates :required_at, presence: true
    validates :package_unit_number, :admission_position,
              numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    validate :version_snapshot_matches
    validate :coordinates_match_scope
    validate :subject_matches_scope
    validate :status_timestamps
    validate :status_transition
    validate :immutable_snapshot
    validate :accepted_requirement_has_evidence
    validate :withdrawn_requirement_has_evidence
    before_destroy :prevent_destroy

    scope :current, -> { where(status: %w[pending accepted]) }
    scope :pending, -> { where(status: "pending") }
    scope :required, -> { where(required: true) }

    def pending? = status == "pending"
    def accepted? = status == "accepted"
    def withdrawn? = status == "withdrawn"
    def superseded? = status == "superseded"

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id registration_id consent_document_version_id required acceptance_scope package_unit_number
        admission_position admission_slot_id subject_user_id status supersedes_requirement_id
        required_reason required_by_id required_at superseded_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration consent_document_version subject_user supersedes_requirement required_by registration_consent]
    end

    private

    def version_snapshot_matches
      return if registration.blank? || consent_document_version.blank?

      document = consent_document_version.consent_document
      if registration.event_id != document.event_id
        errors.add(:consent_document_version, :invalid)
      end
      unless document.active? && acceptable_version?(document)
        errors.add(:consent_document_version, :invalid)
      end
      if acceptance_scope != consent_document_version.acceptance_scope ||
         required != consent_document_version.required
        errors.add(:base, :invalid)
      end
      return unless scoped_document?(document)
      return if document.consent_document_products.any? { |scope| scope.ticket_type_id == registration.ticket_type_id }

      errors.add(:consent_document_version, :invalid)
    end

    def current_version?(document)
      consent_document_version.published? &&
        document.versions.none? { |version| version.published? && version.id != consent_document_version.id }
    end

    def acceptable_version?(document)
      return current_version?(document) unless persisted?

      %w[published retired].include?(consent_document_version.status)
    end

    def scoped_document?(document)
      document.consent_document_products.any?
    end

    def coordinates_match_scope
      if acceptance_scope == "buyer"
        errors.add(:package_unit_number, :invalid) if package_unit_number.present?
        errors.add(:admission_position, :invalid) if admission_position.present?
        errors.add(:admission_slot_id, :invalid) if admission_slot_id.present?
      elsif acceptance_scope == "admission_slot"
        errors.add(:package_unit_number, :invalid) unless positive_integer?(package_unit_number)
        errors.add(:admission_position, :invalid) unless positive_integer?(admission_position)
        errors.add(:admission_slot_id, :invalid) if admission_slot_id.present?
        validate_coordinate_bounds
      end
    end

    def validate_coordinate_bounds
      return if registration.blank?
      return if package_unit_number.blank? || admission_position.blank?

      errors.add(:package_unit_number, :invalid) if package_unit_number > registration.package_quantity
      errors.add(:admission_position, :invalid) if admission_position > registration.admissions_per_unit_snapshot
    end

    def subject_matches_scope
      if acceptance_scope == "buyer"
        errors.add(:subject_user_id, :invalid) unless subject_user_id == registration&.user_id
      elsif %w[accepted withdrawn].include?(status) && subject_user_id.blank?
        errors.add(:subject_user_id, :blank)
      end
      return unless required_reason == "reconsent" && required_by_id.blank?

      errors.add(:required_by_id, :blank)
    end

    def status_timestamps
      if superseded? && superseded_at.blank?
        errors.add(:superseded_at, :blank)
      elsif !superseded? && superseded_at.present?
        errors.add(:superseded_at, :invalid)
      end
    end

    def status_transition
      return unless persisted? && will_save_change_to_status?

      allowed = {
        "pending" => %w[pending accepted withdrawn superseded],
        "accepted" => %w[accepted withdrawn superseded],
        "withdrawn" => %w[withdrawn],
        "superseded" => %w[superseded]
      }
      return if allowed.fetch(status_in_database, []).include?(status)

      errors.add(:status, :invalid)
    end

    def immutable_snapshot
      return unless persisted?

      immutable_fields = %i[
        registration_id consent_document_version_id required acceptance_scope package_unit_number
        admission_position admission_slot_id required_reason required_at
        required_by_id supersedes_requirement_id
      ]
      changed = immutable_fields.select { |field| public_send("will_save_change_to_#{field}?") }
      changed.each { |field| errors.add(field, :immutable) }

      if will_save_change_to_superseded_at? && superseded_at_in_database.present?
        errors.add(:superseded_at, :immutable)
      end

      return unless subject_user_id_changed? && status_in_database != "pending"

      errors.add(:subject_user_id, :immutable)
    end

    def accepted_requirement_has_evidence
      return unless accepted?
      return if registration_consent.present?

      errors.add(:base, :invalid)
    end

    def withdrawn_requirement_has_evidence
      return unless withdrawn?
      return if registration_consent.present? && registration_consent.withdrawal.present?

      errors.add(:base, :invalid)
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def prevent_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_registration_consent_requirement")
    end
  end
end
