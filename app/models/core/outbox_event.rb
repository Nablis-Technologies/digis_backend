# frozen_string_literal: true

module Core
  # A single outbound event awaiting delivery.
  #
  # Written inside the business transaction, published out-of-band by
  # Core::Outbox::Dispatch. Treat `published_at` as the authoritative "done"
  # flag — its presence (not `locked_at`) is what the dispatcher trusts.
  class OutboxEvent < Core::ApplicationRecord
    self.table_name = "core_outbox_events"

    # Polymorphic link back to the aggregate that produced the event.
    belongs_to :aggregate, polymorphic: true, optional: true

    validates :topic, :event_type, :aggregate_type, :aggregate_id, :idempotency_key, presence: true
    validates :attempts, numericality: { greater_than_or_equal_to: 0 }

    # Rows ready to be dispatched: not yet published and past their availability window.
    scope :due, -> { where(published_at: nil).where("available_at <= ?", Time.current) }

    # Datetime columns do not get a `?` predicate automatically; this is the
    # "is this row finished?" check used by the dispatcher.
    def published_at?
      published_at.present?
    end
  end
end
