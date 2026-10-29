# frozen_string_literal: true

module Messaging
  # Tracks one channel attempt for a notification. Provider calls are made by
  # the delivery command outside row locks, while this record remains the
  # durable retry and reconciliation boundary.
  class NotificationDelivery < Messaging::ApplicationRecord
    self.table_name = "messaging_notification_deliveries"

    CHANNELS = %w[in_app email sms].freeze
    STATUSES = %w[pending processing sent delivered failed suppressed unavailable].freeze

    belongs_to :notification,
               class_name: "Messaging::Notification",
               inverse_of: :deliveries

    before_validation :normalize_fields

    validates :notification, :channel, :status, :idempotency_key_digest, presence: true
    validates :channel, inclusion: { in: CHANNELS }
    validates :status, inclusion: { in: STATUSES }
    validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :idempotency_key_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }

    scope :queued, -> { where(status: %w[pending processing]) }
    scope :claimable, lambda {
      queued.where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
    }

    def terminal?
      status.in?(%w[delivered failed suppressed unavailable])
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id notification_id channel status provider provider_message_id attempts
        next_attempt_at claimed_at enqueue_claimed_at scheduled_at sent_at delivered_at failed_at
        failure_code failure_detail created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[notification]
    end

    private

    def normalize_fields
      self.channel = channel.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
      self.provider = provider.to_s.strip.presence
      self.failure_code = failure_code.to_s.strip.presence
      self.failure_detail = failure_detail.to_s.strip.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
    end
  end
end
