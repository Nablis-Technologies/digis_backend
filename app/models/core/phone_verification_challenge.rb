# frozen_string_literal: true

module Core
  # Stores only keyed OTP evidence. The six-digit code is delivered to the
  # phone and is never persisted, logged, or returned through an API.
  class PhoneVerificationChallenge < Core::ApplicationRecord
    self.table_name = "core_phone_verification_challenges"

    STATUSES = %w[pending verified expired exhausted delivery_failed].freeze
    DEFAULT_MAX_ATTEMPTS = 5

    belongs_to :user, class_name: "Core::User"

    validates :purpose, :phone_digest, :code_digest, :idempotency_key_digest,
              :expires_at, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :max_attempts, numericality: { only_integer: true, greater_than: 0 }

    def pending? = status == "pending"
    def verified? = status == "verified"
    def delivery_failed? = status == "delivery_failed"

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id purpose phone_digest status attempts max_attempts expires_at verified_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user]
    end
  end
end
