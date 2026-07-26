# frozen_string_literal: true

module Legal
  class LegalAcceptance < Legal::ApplicationRecord
    self.table_name = "legal_acceptances"

    SUBJECT_TYPES = %w[user organization order].freeze
    ACCEPTANCE_METHODS = %w[checkbox otp].freeze

    belongs_to :legal_document_version,
               class_name: "Legal::LegalDocumentVersion",
               inverse_of: :legal_acceptances
    belongs_to :accepted_by,
               class_name: "Core::User",
               foreign_key: :accepted_by_user_id,
               inverse_of: :legal_acceptances

    validates :subject_type, presence: true, inclusion: { in: SUBJECT_TYPES }
    validates :subject_id, presence: true
    validates :legal_document_version_id, presence: true
    validates :accepted_by_user_id, presence: true
    validates :acceptance_method, presence: true, inclusion: { in: ACCEPTANCE_METHODS }
    validates :content_sha256, presence: true
    validates :evidence_digest, presence: true
    validates :request_uuid, presence: true, uniqueness: { case_sensitive: true }
    validates :accepted_at, presence: true

    validate :subject_must_exist
    validate :version_must_be_published

    def subject
      case subject_type
      when "user" then Core::User.find(subject_id)
      when "organization" then Organizations::Organization.find(subject_id)
      when "order" then Orders::Order.find(subject_id)
      end
    end

    private

    def subject_must_exist
      return if subject_type.blank? || subject_id.blank?
      subject
    rescue ActiveRecord::RecordNotFound
      errors.add(:subject_id, "must reference an existing #{subject_type}")
    end

    def version_must_be_published
      return if legal_document_version_id.blank?
      return if legal_document_version&.published?
      errors.add(:legal_document_version_id, "must be a published version")
    end
  end
end
