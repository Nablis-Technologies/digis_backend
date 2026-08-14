# frozen_string_literal: true

module Events
  # Durable orchestration row for one accepted payment in an event
  # cancellation. Refund rows remain the money source of truth; this row only
  # records bounded work ownership, retry state, and reconciliation progress.
  class EventCancellationPayment < Events::ApplicationRecord
    self.table_name = "events_event_cancellation_payments"

    STATUSES = %w[pending processing resolved failed].freeze

    belongs_to :event_cancellation, class_name: "Events::EventCancellation",
               inverse_of: :payment_snapshots
    belongs_to :payment, class_name: "Orders::Payment", inverse_of: :cancellation_payment_snapshots

    validates :event_cancellation, :payment, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :attempts, :lock_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :resolved_at, presence: true, if: -> { status == "resolved" }
    validates :resolved_at, absence: true, unless: -> { status == "resolved" }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_cancellation_id payment_id status attempts next_retry_at resolved_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_cancellation payment]
    end
  end
end
