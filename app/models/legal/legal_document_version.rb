# frozen_string_literal: true

module Legal
  class LegalDocumentVersion < Legal::ApplicationRecord
    self.table_name = "legal_document_versions"

    STATUSES = %w[draft published retired].freeze

    belongs_to :legal_document,
               class_name: "Legal::LegalDocument",
               inverse_of: :versions
    belongs_to :created_by,
               class_name: "Core::User",
               inverse_of: :legal_document_versions
    belongs_to :published_by,
               class_name: "Core::User",
               inverse_of: :published_legal_document_versions,
               optional: true

    has_many :legal_acceptances,
             class_name: "Legal::LegalAcceptance",
             inverse_of: :legal_document_version

    validates :version, presence: true,
                         numericality: { only_integer: true, greater_than: 0 }
    validates :title, presence: true
    validates :body, presence: true
    validates :content_sha256, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }

    validate :published_requires_metadata, if: :published?
    validate :published_is_immutable, if: -> { published? && !status_changed? }

    scope :published, -> { where(status: "published") }
    scope :draft, -> { where(status: "draft") }
    scope :retired, -> { where(status: "retired") }

    def published?
      status == "published"
    end

    def self.content_sha256_for(title:, body:)
      Digest::SHA256.hexdigest(JSON.generate(title:, body:))
    end

    def self.evidence_digest_for(**attrs)
      Digest::SHA256.hexdigest(
        JSON.generate(
          legal_document_version_id: attrs[:legal_document_version_id],
          content_sha256: attrs[:content_sha256],
          subject_type: attrs[:subject_type],
          subject_id: attrs[:subject_id],
          accepted_by_user_id: attrs[:accepted_by_user_id],
          accepted_by_role: attrs[:accepted_by_role],
          acceptance_method: attrs[:acceptance_method],
          accepted_at: attrs[:accepted_at],
          request_uuid: attrs[:request_uuid]
        )
      )
    end

    private

    def published_requires_metadata
      errors.add(:published_by_id, "is required when published") if published_by_id.blank?
      errors.add(:published_at, "is required when published") if published_at.blank?
    end

    def published_is_immutable
      errors.add(:body, "cannot be changed on a published version") if body_changed?
      errors.add(:content_sha256, "cannot be changed on a published version") if content_sha256_changed?
      errors.add(:title, "cannot be changed on a published version") if title_changed?
      errors.add(:version, "cannot be changed on a published version") if version_changed?
      errors.add(:legal_document_id, "cannot be changed") if legal_document_id_changed?
    end
  end
end
