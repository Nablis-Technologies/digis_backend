# frozen_string_literal: true

module Ticketing
  class RegistrationAnswer < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_answers"

    QUESTION_TYPES = Ticketing::RegistrationQuestion::TYPES
    RESPONSE_SCOPES = Ticketing::RegistrationQuestion::RESPONSE_SCOPES
    TEXT_TYPES = %w[short_text long_text].freeze
    ERASURE_REASONS = %w[legal_request policy_expiry privacy_request security_incident].freeze

    belongs_to :registration_form_submission, class_name: "Ticketing::RegistrationFormSubmission"
    belongs_to :registration_question, class_name: "Ticketing::RegistrationQuestion"
    belongs_to :retention_policy, class_name: "Core::DataRetentionPolicy"

    has_many :revisions,
             class_name: "Ticketing::RegistrationAnswerRevision",
             dependent: :restrict_with_exception

    encrypts :answer_ciphertext

    validates :question_key_snapshot, :question_type_snapshot, :response_scope_snapshot,
              :question_label_snapshot, presence: true
    validates :question_type_snapshot, inclusion: { in: QUESTION_TYPES }
    validates :response_scope_snapshot, inclusion: { in: RESPONSE_SCOPES }
    validates :answered_at, presence: true
    validates :erasure_reason, presence: true, inclusion: { in: ERASURE_REASONS }, if: :erased?

    validate :coordinates_match_scope
    validate :question_snapshot_matches
    validate :retention_deadline
    validate :retention_policy_matches_question
    validate :answer_storage_matches_erasure

    def answer
      original_answer
    end

    def effective_answer
      return if erased? || retention_expired?

      revision = effective_revision
      revision ? revision.answer : original_answer
    end

    def effective_revision
      if association(:revisions).loaded?
        association(:revisions).target
          .reject { |revision| revision.erased? || revision.retention_expired? }
          .max_by(&:revision_number)
      else
        revisions
          .where(erased_at: nil)
          .where("retain_until IS NULL OR retain_until > ?", Time.current)
          .order(revision_number: :desc)
          .first
      end
    end

    def retention_expired?
      retain_until.present? && Time.current >= retain_until
    end

    def original_answer
      return if answer_ciphertext.blank?

      JSON.parse(answer_ciphertext)
    rescue JSON::ParserError
      nil
    end

    def answer=(value)
      @invalid_answer = false
      self.answer_ciphertext = self.class.canonical_json(value)
    rescue ArgumentError, TypeError
      self.answer_ciphertext = nil
      @invalid_answer = true
    end

    def erased?
      erased_at.present?
    end

    def self.canonical_json(value)
      JSON.generate(canonical_value(value))
    end

    def self.canonical_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = canonical_value(child)
        end.sort.to_h
      when Array
        value.map { |child| canonical_value(child) }
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      else
        raise ArgumentError, "answer must contain JSON values"
      end
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id registration_form_submission_id registration_question_id question_key_snapshot
        question_type_snapshot response_scope_snapshot question_label_snapshot package_unit_number
        admission_position admission_slot_id retention_policy_id retain_until answered_at erased_at
        erasure_reason created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration_form_submission registration_question retention_policy revisions]
    end

    private

    def coordinates_match_scope
      if response_scope_snapshot == "registration"
        errors.add(:package_unit_number, :invalid) if package_unit_number.present?
        errors.add(:admission_position, :invalid) if admission_position.present?
        errors.add(:admission_slot_id, :invalid) if admission_slot_id.present?
      elsif response_scope_snapshot == "admission_slot"
        errors.add(:package_unit_number, :invalid) unless positive_integer?(package_unit_number)
        errors.add(:admission_position, :invalid) unless positive_integer?(admission_position)
        validate_coordinate_bounds
      end
    end

    def question_snapshot_matches
      return if registration_question.blank?

      errors.add(:question_key_snapshot, :invalid) if registration_question.key != question_key_snapshot
      errors.add(:question_type_snapshot, :invalid) if registration_question.type != question_type_snapshot
      errors.add(:response_scope_snapshot, :invalid) if registration_question.response_scope != response_scope_snapshot
      errors.add(:question_label_snapshot, :invalid) if registration_question.label != question_label_snapshot

      return if registration_form_submission.blank?
      return if registration_question.registration_form_version_id ==
                registration_form_submission.registration_form_version_id

      errors.add(:registration_question, :invalid)
    end

    def retention_deadline
      return if retention_policy.blank?

      if retention_policy.retention_days.blank?
        errors.add(:retain_until, :invalid) if retain_until.present?
        return
      end

      expected_deadline = answered_at && answered_at + retention_policy.retention_days.days
      return if expected_deadline.present? && retain_until == expected_deadline

      errors.add(:retain_until, :invalid)
    end

    def retention_policy_matches_question
      return if retention_policy.blank? || answered_at.blank?

      expected_category = TEXT_TYPES.include?(question_type_snapshot) ?
        "registration_free_text" : "registration_structured"
      return if retention_policy.status == "active" &&
                retention_policy.category == expected_category &&
                retention_policy.effective_at.present? &&
                retention_policy.effective_at <= answered_at

      errors.add(:retention_policy, :invalid)
    end

    def answer_storage_matches_erasure
      if erased?
        errors.add(:answer_ciphertext, :invalid) if answer_ciphertext.present?
      elsif answer_ciphertext.blank? || @invalid_answer
        errors.add(:answer_ciphertext, :blank)
      elsif answer.nil? && answer_ciphertext.present?
        errors.add(:answer_ciphertext, :invalid)
      elsif erasure_reason.present?
        errors.add(:erasure_reason, :invalid)
      end
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def validate_coordinate_bounds
      registration = registration_form_submission&.registration
      return if registration.blank?
      return if registration.package_quantity.blank? || registration.admissions_per_unit_snapshot.blank?

      if package_unit_number > registration.package_quantity
        errors.add(:package_unit_number, :invalid)
      end
      return unless admission_position > registration.admissions_per_unit_snapshot

      errors.add(:admission_position, :invalid)
    end
  end
end
