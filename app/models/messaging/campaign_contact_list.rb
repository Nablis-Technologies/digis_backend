# frozen_string_literal: true

module Messaging
  # Reusable organization-owned contact collection.
  class CampaignContactList < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_contact_lists"

    STATUSES = %w[active archived].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :created_by, class_name: "Core::User"
    has_many :entries,
             class_name: "Messaging::CampaignContactListEntry",
             foreign_key: :campaign_contact_list_id,
             inverse_of: :campaign_contact_list,
             dependent: :destroy
    has_many :imports,
             class_name: "Messaging::CampaignContactListImport",
             foreign_key: :campaign_contact_list_id,
             inverse_of: :campaign_contact_list,
             dependent: :destroy

    before_validation :normalize_fields

    validates :organization, :created_by, :name, :status, :version, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :version, numericality: { only_integer: true, greater_than: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id created_by_id name status version created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization created_by entries imports]
    end

    private

    def normalize_fields
      self.name = name.to_s.strip.presence
      self.status = status.to_s.strip.downcase.presence
    end
  end
end
