# frozen_string_literal: true

module Core
  # Marks expired OTP challenges in bounded batches. It only cleans verification
  # evidence; account and ticket state remain elsewhere.
  class ExpirePhoneVerificationChallengesJob < ApplicationJob
    queue_as :maintenance
    BATCH_SIZE = 500

    def perform
      Core::PhoneVerificationChallenge
        .where(status: %w[pending delivery_failed])
        .where("expires_at <= ?", Time.current)
        .order(:id)
        .limit(BATCH_SIZE)
        .update_all(status: "expired", updated_at: Time.current)
    end
  end
end
