# frozen_string_literal: true

require "test_helper"

module Core
  module PhoneVerification
    class VerificationTest < ActiveSupport::TestCase
      setup do
        @user = Core::User.create!(phone: "+251911000051")
        @delivered_codes = []
        @previous_sender = Rails.application.config.x.phone_verification_sender
        Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
          @delivered_codes << { phone:, code:, challenge_id: challenge.id }
        end
      end

      teardown do
        Rails.application.config.x.phone_verification_sender = @previous_sender
      end

      test "delivers one code and accepts it once" do
        requested = Request.call(
          user: @user,
          phone: @user.phone,
          purpose: "guest_claim",
          idempotency_key: "otp-request-51"
        )

        assert_predicate requested, :success?, requested.error&.message
        assert_equal 1, @delivered_codes.length
        code = @delivered_codes.first.fetch(:code)
        verified = Verify.call(challenge: requested.value, code:)

        assert_predicate verified, :success?, verified.error&.message
        assert verified.value.token.present?
        replay = Verify.call(challenge: requested.value, code:)
        assert_predicate replay, :failure?
        assert_equal "verification_already_used", replay.error.code
      end

      test "accepts a guest proof only for its verified challenge and phone identity" do
        token = guest_admission_proof

        assert Verify.valid_proof?(
          token:,
          phone: "0911000051",
          user_id: @user.id,
          purpose: "guest_admission"
        )
      end

      test "rejects guest proofs with a changed phone, user, or purpose" do
        token = guest_admission_proof
        other_user = Core::User.create!(phone: "+251911000052")

        assert_not Verify.valid_proof?(
          token:, phone: "+251911000052", user_id: @user.id, purpose: "guest_admission"
        )
        assert_not Verify.valid_proof?(
          token:, phone: @user.phone, user_id: other_user.id, purpose: "guest_admission"
        )
        assert_not Verify.valid_proof?(
          token:, phone: @user.phone, user_id: @user.id, purpose: "guest_claim"
        )
        assert_not Verify.valid_proof?(
          token: "tampered", phone: @user.phone, user_id: @user.id, purpose: "guest_admission"
        )
      end

      test "rejects a signed proof after its challenge is no longer verified" do
        token = guest_admission_proof
        challenge = PhoneVerificationChallenge.find(@delivered_codes.last.fetch(:challenge_id))
        challenge.update_columns(status: "pending", verified_at: nil)

        assert_not Verify.valid_proof?(
          token:, phone: @user.phone, user_id: @user.id, purpose: "guest_admission"
        )
      end

      test "rejects a proof after its verified challenge expires" do
        token = guest_admission_proof
        challenge = PhoneVerificationChallenge.find(@delivered_codes.last.fetch(:challenge_id))
        challenge.update_column(:expires_at, 1.second.ago)

        assert_not Verify.valid_proof?(
          token:, phone: @user.phone, user_id: @user.id, purpose: "guest_admission"
        )
      end

      test "replaying the request key returns the same challenge without redelivery" do
        first = Request.call(
          user: @user,
          phone: "0911000051",
          purpose: "guest_claim",
          idempotency_key: "otp-request-replay-51"
        )
        second = Request.call(
          user: @user,
          phone: "+251911000051",
          purpose: "guest_claim",
          idempotency_key: "otp-request-replay-51"
        )

        assert_predicate first, :success?
        assert_predicate second, :success?
        assert_equal first.value.id, second.value.id
        assert_equal 1, @delivered_codes.length
      end

      test "persists the real code digest without a follow-up challenge update" do
        updates = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          sql = payload[:sql].to_s
          updates << sql if sql.match?(/UPDATE\s+"core_phone_verification_challenges"/i)
        end

        challenge = Request.call(
          user: @user,
          phone: @user.phone,
          purpose: "guest_claim",
          idempotency_key: "otp-request-single-write-51"
        ).value

        assert_empty updates
        assert_equal Core::KeyedDigest.digest(
          namespace: "core-phone-verification/#{@user.id}/guest_claim",
          value: @delivered_codes.last.fetch(:code)
        ), challenge.code_digest
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      test "does not replay an undelivered challenge under the same key" do
        Rails.application.config.x.phone_verification_sender = lambda do |**|
          raise "provider unavailable"
        end

        first = Request.call(
          user: @user,
          phone: @user.phone,
          purpose: "guest_claim",
          idempotency_key: "otp-request-delivery-failure-51"
        )

        assert_predicate first, :failure?
        assert_equal "delivery_failed", first.error.code
        challenge = PhoneVerificationChallenge.find_by!(
          user: @user,
          purpose: "guest_claim",
          idempotency_key_digest: Core::IdempotencyKey.new("otp-request-delivery-failure-51").digest
        )
        assert_equal "delivery_failed", challenge.status

        replay = Request.call(
          user: @user,
          phone: @user.phone,
          purpose: "guest_claim",
          idempotency_key: "otp-request-delivery-failure-51"
        )

        assert_predicate replay, :failure?
        assert_equal "delivery_failed", replay.error.code
      end

      test "exhausts a challenge after five incorrect codes" do
        requested = Request.call(
          user: @user,
          phone: @user.phone,
          purpose: "guest_claim",
          idempotency_key: "otp-request-attempts-51"
        )

        verification_attempts = -> { 5.times { Verify.call(challenge: requested.value, code: "000000") } }
        defined?(Prosopite) ? Prosopite.pause(&verification_attempts) : verification_attempts.call
        result = Verify.call(challenge: requested.value, code: @delivered_codes.first.fetch(:code))

        assert_predicate result, :failure?
        assert_equal "attempts_exhausted", result.error.code
      end

      private

      def guest_admission_proof
        challenge = Request.call(
          user: @user,
          phone: @user.phone,
          purpose: "guest_admission",
          idempotency_key: "guest-proof-#{SecureRandom.hex(5)}"
        ).value
        Verify.call(challenge:, code: @delivered_codes.last.fetch(:code)).value.token
      end
    end
  end
end
