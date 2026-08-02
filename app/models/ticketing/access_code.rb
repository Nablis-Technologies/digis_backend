# frozen_string_literal: true

module Ticketing
  # Shared codes that authorize a ticket product. The raw code is normalized,
  # encrypted at rest for idempotent replay, and hashed for lookup.
  class AccessCode < Ticketing::ApplicationRecord
    self.table_name = "ticketing_access_codes"

    belongs_to :ticket_type, class_name: "Ticketing::TicketType", inverse_of: :access_codes

    encrypts :code_ciphertext

    def code
      code_ciphertext
    end

    def code=(value)
      self.code_ciphertext = value
    end

    validates :ticket_type, presence: true
    validates :code_digest, presence: true,
             uniqueness: { scope: :ticket_type_id, message: ->(*_args) { I18n.t("ticketing.access_code.errors.already_used") } }
    validates :used_count,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :max_quantity_per_use,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :max_uses,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 },
              allow_nil: true
    validate :expiry_after_start

    scope :active, -> { where(active: true) }
    scope :usable_now, -> do
      where(active: true)
        .where("(starts_at IS NULL OR starts_at <= now())")
        .where("(expires_at IS NULL OR expires_at > now())")
    end

    def self.code_digest_for(event_id:, code:)
      Core::KeyedDigest.digest(namespace: event_id, value: code)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id ticket_type_id code_digest label max_uses used_count
        max_quantity_per_use starts_at expires_at active created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket_type]
    end

    private

    def expiry_after_start
      return if starts_at.blank? || expires_at.blank?
      return if expires_at > starts_at

      errors.add(:expires_at, I18n.t("ticketing.access_code.errors.expires_after_start"))
    end
  end
end
