# frozen_string_literal: true

module Ticketing
  # Append-only ownership history for a package transfer. Pending rows preserve
  # the original owner and credential generation; only recipient acceptance may
  # create a newer generation and change the package owner.
  class TicketTransfer < Ticketing::ApplicationRecord
    self.table_name = "ticketing_ticket_transfers"

    STATUSES = %w[pending accepted declined cancelled expired].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :ticket_transfers
    belongs_to :from_user, class_name: "Core::User", inverse_of: :outgoing_ticket_transfers
    belongs_to :to_user, class_name: "Core::User", inverse_of: :incoming_ticket_transfers
    belongs_to :initiated_by, class_name: "Core::User", inverse_of: :initiated_ticket_transfers

    validates :token_digest, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :previous_version, numericality: { only_integer: true, greater_than: 0 }
    validates :expires_at, presence: true
    validate :recipient_is_different
    validate :lifecycle_timestamps_match

    scope :pending, -> { where(status: "pending") }

    def self.token_digest_for(token:)
      Core::KeyedDigest.digest(namespace: "ticketing-ticket-transfer", value: token)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id ticket_id from_user_id to_user_id initiated_by_id token_digest status previous_version
        new_version reason expires_at accepted_at declined_at cancelled_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket from_user to_user initiated_by]
    end

    private

    def recipient_is_different
      return if from_user_id.blank? || to_user_id.blank? || from_user_id != to_user_id

      errors.add(:to_user, :invalid)
    end

    def lifecycle_timestamps_match
      if status == "accepted"
        errors.add(:new_version, :blank) if new_version.blank?
        errors.add(:accepted_at, :blank) if accepted_at.blank?
      else
        errors.add(:new_version, :invalid) if new_version.present?
        errors.add(:accepted_at, :invalid) if accepted_at.present?
      end

      if status == "declined"
        errors.add(:declined_at, :blank) if declined_at.blank?
      elsif declined_at.present?
        errors.add(:declined_at, :invalid)
      end

      if status == "cancelled"
        errors.add(:cancelled_at, :blank) if cancelled_at.blank?
      elsif cancelled_at.present?
        errors.add(:cancelled_at, :invalid)
      end
    end
  end
end
