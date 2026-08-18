# frozen_string_literal: true

module Events
  # The single, irreversible cancellation of an event. At most one row can exist
  # per event (enforced by a unique index), which is what makes cancellation a
  # one-way boundary.
  class EventCancellation < Events::ApplicationRecord
    self.table_name = "events_event_cancellations"
    self.inheritance_column = nil

    STATUSES = %w[pending processing completed partially_failed].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :initiated_by, class_name: "Core::User"
    has_many :refunds,
             class_name: "Orders::Refund",
             inverse_of: :event_cancellation,
             dependent: :restrict_with_exception
    has_many :payment_snapshots,
             class_name: "Events::EventCancellationPayment",
             inverse_of: :event_cancellation,
             dependent: :restrict_with_exception
    has_many :date_changes,
             class_name: "Events::EventDateChange",
             inverse_of: :event_cancellation,
             dependent: :restrict_with_exception

    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :idempotency_key, :attendee_reason, :initiated_at, presence: true
    validates :total_payments_count, :resolved_payments_count, :failed_payments_count, :lock_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :counters_within_total

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id initiated_by_id attendee_reason internal_note status
         total_payments_count resolved_payments_count failed_payments_count initiated_at
         refunds_started_at completed_at last_error lock_version created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event initiated_by refunds payment_snapshots date_changes]
    end

    private

    def counters_within_total
      return if total_payments_count.blank? || resolved_payments_count.blank? || failed_payments_count.blank?
      return if resolved_payments_count + failed_payments_count <= total_payments_count

      errors.add(:base, :invalid)
    end
  end
end
