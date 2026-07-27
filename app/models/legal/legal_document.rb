# frozen_string_literal: true

module Legal
  class LegalDocument < Legal::ApplicationRecord
    self.table_name = "legal_documents"

    DOCUMENT_TYPES = %w[
      platform_terms privacy_policy organizer_agreement
      organizer_fee_schedule buyer_purchase_terms
    ].freeze

    belongs_to :created_by, class_name: "Core::User", inverse_of: :legal_documents
    has_many :versions,
             class_name: "Legal::LegalDocumentVersion",
             inverse_of: :legal_document,
             dependent: :restrict_with_exception

    validates :document_type, presence: true, inclusion: { in: DOCUMENT_TYPES }
    validates :document_type, uniqueness: { scope: %i[jurisdiction_code locale] }
    validates :internal_name, presence: true
    validates :jurisdiction_code, presence: true
    validates :locale, presence: true
    validates :active, inclusion: { in: [ true, false ] }

    scope :active, -> { where(active: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id document_type internal_name jurisdiction_code locale active created_by_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[created_by versions]
    end
  end
end
