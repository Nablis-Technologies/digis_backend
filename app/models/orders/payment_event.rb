# frozen_string_literal: true

module Orders
  # Durable provider-event inbox row. The unique provider identity makes HTTP
  # retries safe, while the attempt/error fields let a worker resume after a
  # crash without retaining provider secrets in operational diagnostics.
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
    validates :attempts_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def processed? = status == "processed"

    def terminal? = status.in?(%w[processed ignored])

    def self.ransackable_attributes(_auth_object = nil)
      %w[id payment_id provider provider_event_id event_type status occurred_at received_at processed_at attempts_count created_at updated_at]
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
