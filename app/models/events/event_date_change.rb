# frozen_string_literal: true

module Events
  # Append-only record of a single schedule change. Rows are never updated;
  # each reschedule writes a fresh, immutable old/new snapshot.
  class EventDateChange < Events::ApplicationRecord
    self.table_name = "events_event_date_changes"
    self.inheritance_column = nil

    CHANGE_TYPES = %w[reschedule cancelled].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :event_date, class_name: "Events::EventDate"
    belongs_to :event_cancellation,
               class_name: "Events::EventCancellation",
               optional: true,
               inverse_of: :date_changes
    belongs_to :scheduled_by, class_name: "Core::User"
    has_many :refund_items,
             class_name: "Orders::RefundItem",
             inverse_of: :event_date_change,
             dependent: :restrict_with_exception

    validates :change_type, presence: true, inclusion: { in: CHANGE_TYPES }
    validates :old_start_at, :old_end_at, presence: true
    validates :new_start_at, :new_end_at, presence: true, if: :reschedule?
    validate :cancelled_schedule_is_open_ended

    # Append-only: snapshots are created but never edited or deleted.
    before_update :prevent_mutation
    before_destroy :prevent_mutation

    def reschedule?
      change_type == "reschedule"
    end

    def cancelled_schedule_is_open_ended
      return unless change_type == "cancelled"
      return if new_start_at.blank? && new_end_at.blank?

      errors.add(:base, :invalid)
    end

    def prevent_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_event_date_change")
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id event_date_id change_type old_start_at old_end_at
         new_start_at new_end_at event_cancellation_id scheduled_by_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event event_date event_cancellation scheduled_by]
    end
  end
end
