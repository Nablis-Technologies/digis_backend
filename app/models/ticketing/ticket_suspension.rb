# frozen_string_literal: true

module Ticketing
  # Append-only review case for a temporarily suspended package. The case owns
  # the human-readable lifecycle; admission consumers read the separate
  # Ticketing::Revocation projection for a monotonic offline-safe decision.
  class TicketSuspension < Ticketing::ApplicationRecord
    self.table_name = "ticketing_ticket_suspensions"

    REASON_CODES = %w[suspected_fraud identity_review chargeback_review safety_review].freeze
    STATUSES = %w[active restored revoked_free cancelled_refunded expired].freeze
    RESOLUTION_REASONS = %w[review_cleared organizer_cancellation refund_succeeded review_deadline_expired].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :ticket_suspensions
    belongs_to :event, class_name: "Events::Event"
    belongs_to :initiated_by, class_name: "Core::User"
    belongs_to :resolved_by, class_name: "Core::User", optional: true

    encrypts :internal_note_ciphertext

    def internal_note
      internal_note_ciphertext
    end

    def internal_note=(value)
      self.internal_note_ciphertext = value.to_s.presence
    end

    validates :ticket, :event, :initiated_by, :reason_code, :status, :review_deadline_at, :idempotency_key,
              presence: true
    validates :reason_code, inclusion: { in: REASON_CODES }
    validates :status, inclusion: { in: STATUSES }
    validates :resolution_reason, inclusion: { in: RESOLUTION_REASONS }, allow_nil: true
    validates :idempotency_key, uniqueness: true

    validate :event_scope_matches
    validate :review_deadline_is_bounded
    validate :resolution_shape

    scope :active, -> { where(status: "active") }
    scope :overdue, -> { active.where("review_deadline_at <= ?", Time.current) }

    def resolved?
      status != "active"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id ticket_id event_id initiated_by_id reason_code status review_deadline_at resolved_by_id
         resolution_reason resolved_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket event initiated_by resolved_by]
    end

    private

    def event_scope_matches
      return if ticket.blank? || event_id.blank?
      return if ticket.event_id == event_id

      errors.add(:event, :invalid)
    end

    def review_deadline_is_bounded
      return if review_deadline_at.blank?
      return unless status == "active"
      return if review_deadline_at > Time.current && review_deadline_at <= 30.days.from_now

      errors.add(:review_deadline_at, :invalid)
    end

    def resolution_shape
      if status == "active"
        errors.add(:resolved_by, :present) if resolved_by_id.present?
        errors.add(:resolution_reason, :present) if resolution_reason.present?
        errors.add(:resolved_at, :present) if resolved_at.present?
      else
        errors.add(:resolved_by, :blank) if resolved_by_id.blank?
        errors.add(:resolution_reason, :blank) if resolution_reason.blank?
        errors.add(:resolved_at, :blank) if resolved_at.blank?
      end
    end
  end
end
