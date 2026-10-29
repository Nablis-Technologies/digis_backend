# frozen_string_literal: true

require "test_helper"

module Core
  class ExpirePhoneVerificationChallengesJobTest < ActiveJob::TestCase
    test "expires only pending challenges past their deadline" do
      user = Core::User.create!(phone: "+251911000091")
      common = {
        user:,
        purpose: "guest_claim",
        phone_digest: "a" * 64,
        code_digest: "b" * 64,
        idempotency_key_digest: "c" * 64,
        attempts: 0,
        max_attempts: 5
      }
      expired = Core::PhoneVerificationChallenge.create!(common.merge(expires_at: 1.minute.ago))
      active = Core::PhoneVerificationChallenge.create!(common.merge(
        idempotency_key_digest: "d" * 64, expires_at: 10.minutes.from_now
      ))

      ExpirePhoneVerificationChallengesJob.perform_now

      assert_equal "expired", expired.reload.status
      assert_equal "pending", active.reload.status
    end

    test "expires a delivery-failed challenge past its deadline" do
      user = Core::User.create!(phone: "+251911000092")
      challenge = Core::PhoneVerificationChallenge.create!(
        user:,
        purpose: "guest_claim",
        phone_digest: "a" * 64,
        code_digest: "b" * 64,
        idempotency_key_digest: "c" * 64,
        status: "delivery_failed",
        attempts: 0,
        max_attempts: 5,
        expires_at: 1.minute.ago
      )

      ExpirePhoneVerificationChallengesJob.perform_now

      assert_equal "expired", challenge.reload.status
    end
  end
end
