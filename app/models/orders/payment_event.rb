# frozen_string_literal: true

module Orders
  # Durable provider-event identity. Task 7 will add receipt and processing
  # commands; this model already owns the deduplication key so callbacks can
  # never create two histories for one provider event.
  class PaymentEvent < Orders::ApplicationRecord
    self.table_name = "orders_payment_events"

    STATUSES = %w[received processing processed failed ignored].freeze

    belongs_to :payment,
               class_name: "Orders::Payment",
               inverse_of: :payment_events,
               optional: true

    before_validation :normalize_fields

    validates :provider, :provider_event_id, :event_type, :payload_digest, :received_at,
              presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :payload, presence: true
    validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }

    def processed? = status == "processed"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id payment_id provider provider_event_id event_type status occurred_at received_at processed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[payment]
    end

    private

    def normalize_fields
      self.provider = provider.to_s.strip.downcase.presence
      self.provider_event_id = provider_event_id.to_s.strip.presence
      self.event_type = event_type.to_s.strip.downcase.presence
      self.payload_digest = payload_digest.to_s.strip.downcase.presence
    end
  end
end
