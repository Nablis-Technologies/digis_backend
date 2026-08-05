# frozen_string_literal: true

module Events
  class ConsentDocument < Events::ApplicationRecord
    self.table_name = "events_consent_documents"
    self.inheritance_column = nil

    TYPES = %w[terms liability_waiver media_consent age_declaration other].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :consent_documents
    belongs_to :created_by, class_name: "Core::User", inverse_of: :consent_documents
    has_many :versions,
             class_name: "Events::ConsentDocumentVersion",
             inverse_of: :consent_document,
             dependent: :destroy
    has_many :consent_document_products,
             class_name: "Events::ConsentDocumentProduct",
             inverse_of: :consent_document,
             dependent: :destroy

    validates :type, presence: true, inclusion: { in: TYPES }
    validates :name, presence: true
    validates :active, inclusion: { in: [ true, false ] }

    scope :active, -> { where(active: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id name type active created_by_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event created_by versions]
    end
  end
end
