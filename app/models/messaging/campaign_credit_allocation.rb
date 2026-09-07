# frozen_string_literal: true

module Messaging
  # One delivery's allocation against the aggregate campaign credit hold.
  class CampaignCreditAllocation < Messaging::ApplicationRecord
    self.table_name = "messaging_campaign_credit_allocations"

    STATUSES = %w[allocated consumed released refunded].freeze

    belongs_to :campaign, class_name: "Messaging::Campaign", inverse_of: :credit_allocations
    belongs_to :delivery,
               class_name: "Messaging::CampaignDelivery",
               inverse_of: :credit_allocation
    belongs_to :credit_reservation,
               class_name: "Messaging::CreditReservation",
               inverse_of: :allocations

    before_validation :normalize_fields

    validates :campaign, :delivery, :credit_reservation, :quantity, :status,
      :idempotency_key_digest, presence: true
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :status, inclusion: { in: STATUSES }
    validates :idempotency_key_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validate :resolution_matches_status

    def terminal? = status != "allocated"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id campaign_id delivery_id credit_reservation_id quantity status resolution_code resolved_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[campaign delivery credit_reservation]
    end

    private

    def normalize_fields
      self.status = status.to_s.strip.downcase.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.resolution_code = resolution_code.to_s.strip.presence
    end

    def resolution_matches_status
      return if status == "allocated" && resolved_at.blank?
      return if status != "allocated" && resolved_at.present?

      errors.add(:resolved_at, :invalid)
    end
  end
end
