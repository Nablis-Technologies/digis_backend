# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class ClaimGuestTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @shadow = Core::User.create!(phone: "+251911000061")
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Guest claim #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: { audience: "public", approval_mode: "automatic", date_selection: "fixed" },
          inventory_configuration: { mode: "unlimited" }
        ).value
        @registration = Registration.create!(
          event: @event,
          ticket_type: product.ticket_type,
          user: @shadow,
          created_by: @shadow,
          source: "self_service",
          identity_digest: Core::PhoneIdentity::ResolveOrCreate.digest_for("251911000061"),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "confirmed",
          submitted_at: Time.current,
          confirmed_at: Time.current
        )
        @codes = []
        @previous_sender = Rails.application.config.x.phone_verification_sender
        Rails.application.config.x.phone_verification_sender = lambda { |code:, **| @codes << code }
      end

      teardown do
        Rails.application.config.x.phone_verification_sender = @previous_sender
      end

      test "claims the shadow registration after OTP verification and returns auth tokens" do
        challenge = Core::PhoneVerification::Request.call(
          user: @shadow,
          phone: @shadow.phone,
          purpose: "guest_claim",
          idempotency_key: "claim-otp-61"
        ).value
        proof = Core::PhoneVerification::Verify.call(challenge:, code: @codes.last).value.token

        result = ClaimGuest.call(
          registration: @registration,
          phone: @shadow.phone,
          verification_token: proof,
          password: "password123",
          password_confirmation: "password123",
          idempotency_key: "claim-registration-61",
          request: ActionDispatch::TestRequest.create
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal @shadow.id, result.value.user.id
        assert @shadow.reload.verified_at.present?
        assert @shadow.authenticate("password123")
        assert result.value.access_token.present?
        assert result.value.refresh_token.present?
      end

      test "rejects a claim with a proof for a different user" do
        other = Core::User.create!(phone: "+251911000062")
        challenge = Core::PhoneVerification::Request.call(
          user: other,
          phone: other.phone,
          purpose: "guest_claim",
          idempotency_key: "claim-otp-62"
        ).value
        proof = Core::PhoneVerification::Verify.call(challenge:, code: @codes.last).value.token

        result = ClaimGuest.call(
          registration: @registration,
          phone: @shadow.phone,
          verification_token: proof,
          password: "password123",
          password_confirmation: "password123",
          idempotency_key: "claim-registration-62",
          request: ActionDispatch::TestRequest.create
        )

        assert_predicate result, :failure?
        assert_equal "claim_user_mismatch", result.error.code
        assert_nil @shadow.reload.verified_at
      end

      test "replays the same claim key with the same result shape and one audit" do
        challenge = Core::PhoneVerification::Request.call(
          user: @shadow,
          phone: @shadow.phone,
          purpose: "guest_claim",
          idempotency_key: "claim-otp-replay-61"
        ).value
        proof = Core::PhoneVerification::Verify.call(challenge:, code: @codes.last).value.token
        arguments = {
          registration: @registration,
          phone: @shadow.phone,
          verification_token: proof,
          password: "password123",
          password_confirmation: "password123",
          idempotency_key: "claim-registration-replay-61",
          request: ActionDispatch::TestRequest.create
        }

        first = ClaimGuest.call(**arguments)
        replay = ClaimGuest.call(**arguments)

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.user.id, replay.value.user.id
        assert replay.value.access_token.present?
        assert replay.value.refresh_token.present?
        assert_equal 1, Core::AuditLog.where(
          action: "ticketing.registration.guest_claimed", auditable_id: @registration.id
        ).count
      end
    end
  end
end
