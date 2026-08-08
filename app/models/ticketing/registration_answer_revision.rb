# frozen_string_literal: true

module Ticketing
  # An append-only correction to a registration answer. It inherits the source
  # answer's retention deadline so a correction can never extend the lifetime of
  # sensitive attendee data.
  class RegistrationAnswerRevision < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_answer_revisions"

    SOURCES = %w[attendee_correction manager_correction].freeze
    REASON_CODES = %w[attendee_request data_quality legal_requirement accessibility_correction].freeze

    belongs_to :registration_answer, class_name: "Ticketing::RegistrationAnswer"
    belongs_to :revised_by, class_name: "Core::User"

    encrypts :answer_ciphertext

    before_validation :inherit_retention_deadline

    validates :revision_number, presence: true,
                               numericality: { only_integer: true, greater_than: 0 }
    validates :source, presence: true, inclusion: { in: SOURCES }
    validates :idempotency_key_digest, presence: true,
                                       format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: true
    validates :request_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :revised_at, presence: true
    validates :reason_code, presence: true, inclusion: { in: REASON_CODES }, if: :manager_correction?
    validates :reason_code, inclusion: { in: REASON_CODES }, allow_nil: true, unless: :manager_correction?

    validate :answer_storage_matches_erasure
    validate :revision_is_monotonic

    def answer
      return if answer_ciphertext.blank?

      JSON.parse(answer_ciphertext)
    rescue JSON::ParserError
      nil
    end

    def answer=(value)
      @invalid_answer = false
      self.answer_ciphertext = RegistrationAnswer.canonical_json(value)
    rescue ArgumentError, TypeError
      self.answer_ciphertext = nil
      @invalid_answer = true
    end

    def erased?
      erased_at.present?
    end

    def retention_expired?
      retain_until.present? && Time.current >= retain_until
    end

    def manager_correction?
      source == "manager_correction"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id registration_answer_id revision_number revised_by_id source reason_code
        idempotency_key_digest request_digest revised_at retain_until erased_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration_answer revised_by]
    end

    private

    def inherit_retention_deadline
      # Do not accept a caller-supplied deadline on a correction.
      self.retain_until = registration_answer.retain_until if registration_answer
    end

    def answer_storage_matches_erasure
      if erased?
        errors.add(:answer_ciphertext, :invalid) if answer_ciphertext.present?
      elsif answer_ciphertext.blank? || @invalid_answer
        errors.add(:answer_ciphertext, :blank)
      elsif answer.nil?
        errors.add(:answer_ciphertext, :invalid)
      end
    end

    def revision_is_monotonic
      return if registration_answer.blank? || revision_number.blank?

      previous_revision = self.class
        .where(registration_answer_id: registration_answer_id)
        .where.not(id: id)
        .maximum(:revision_number)
      return if previous_revision.blank? || revision_number > previous_revision

      errors.add(:revision_number, :greater_than, count: previous_revision)
    end
  end
end
