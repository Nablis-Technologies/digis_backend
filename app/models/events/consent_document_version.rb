# frozen_string_literal: true

module Events
  class ConsentDocumentVersion < Events::ApplicationRecord
    self.table_name = "events_consent_document_versions"

    STATUSES = %w[draft published retired].freeze
    ACCEPTANCE_SCOPES = %w[buyer admission_slot].freeze

    belongs_to :consent_document,
               class_name: "Events::ConsentDocument",
               inverse_of: :versions
    belongs_to :created_by,
               class_name: "Core::User",
               inverse_of: :consent_document_versions
    belongs_to :published_by,
               class_name: "Core::User",
               inverse_of: :published_consent_document_versions,
               optional: true

    validates :version, presence: true,
                         numericality: { only_integer: true, greater_than: 0 }
    validates :title, presence: true
    validates :body, presence: true
    validates :content_sha256, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :acceptance_scope, inclusion: { in: ACCEPTANCE_SCOPES }, allow_nil: true
    validates :required, inclusion: { in: [ true, false ] }

    validate :published_requires_metadata, if: :published?
    validate :published_is_immutable, if: -> { published? && !status_changed? }

    scope :published, -> { where(status: "published") }
    scope :draft, -> { where(status: "draft") }
    scope :retired, -> { where(status: "retired") }
    scope :for_public, -> { published }

    def published?
      status == "published"
    end

    def self.content_sha256_for(type:, title:, body:)
      Digest::SHA256.hexdigest(JSON.generate(type:, title:, body:))
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
      errors.add(:consent_document_id, "cannot be changed") if consent_document_id_changed?
    end
  end
end
