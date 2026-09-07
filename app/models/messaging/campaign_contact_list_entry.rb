# frozen_string_literal: true

module Messaging
  # Encrypted contact values plus keyed lookup digests for one saved list row.
  class CampaignContactListEntry < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_contact_list_entries"

    STATUSES = %w[active removed].freeze

    belongs_to :campaign_contact_list,
               class_name: "Messaging::CampaignContactList",
               inverse_of: :entries

    encrypts :phone_number_ciphertext, :email_ciphertext,
      :first_name_ciphertext, :last_name_ciphertext

    def phone_number = phone_number_ciphertext

    def phone_number=(value)
      self.phone_number_ciphertext = value.to_s.strip.presence
    end

    def email = email_ciphertext

    def email=(value)
      self.email_ciphertext = value.to_s.strip.presence
    end

    def first_name = first_name_ciphertext

    def first_name=(value)
      self.first_name_ciphertext = value.to_s.strip.presence
    end

    def last_name = last_name_ciphertext

    def last_name=(value)
      self.last_name_ciphertext = value.to_s.strip.presence
    end

    before_validation :normalize_fields

    validates :campaign_contact_list, :status, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :phone_digest, :email_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validate :address_present

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_contact_list_id phone_digest email_digest source status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign_contact_list]
    end

    private

    def normalize_fields
      self.phone_digest = phone_digest.to_s.strip.downcase.presence
      self.email_digest = email_digest.to_s.strip.downcase.presence
      self.source = source.to_s.strip.presence
      self.status = status.to_s.strip.downcase.presence
    end

    def address_present
      errors.add(:base, :contact_required) if phone_digest.blank? && email_digest.blank?
    end
  end
end
