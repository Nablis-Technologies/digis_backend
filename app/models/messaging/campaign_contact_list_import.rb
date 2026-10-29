# frozen_string_literal: true

module Messaging
  # Asynchronous CSV import state and sanitized rejected-row report.
  class CampaignContactListImport < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_contact_list_imports"

    STATUSES = %w[pending processing completed failed].freeze

    belongs_to :campaign_contact_list,
               class_name: "Messaging::CampaignContactList",
               inverse_of: :imports
    belongs_to :created_by, class_name: "Core::User"
    has_one_attached :file
    has_one_attached :rejected_report

    before_validation :normalize_fields

    validates :campaign_contact_list, :created_by, :status, :idempotency_key_digest,
      :request_digest, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :idempotency_key_digest, :request_digest,
      format: { with: /\A[0-9a-f]{64}\z/ }
    validates :total_rows, :accepted_rows, :duplicate_rows, :invalid_rows,
      :suppressed_rows, :missing_channel_rows,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_contact_list_id created_by_id status filename total_rows accepted_rows duplicate_rows invalid_rows suppressed_rows missing_channel_rows started_at completed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign_contact_list created_by file_attachment rejected_report_attachment]
    end

    private

    def normalize_fields
      self.status = status.to_s.strip.downcase.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.request_digest = request_digest.to_s.strip.downcase.presence
    end
  end
end
