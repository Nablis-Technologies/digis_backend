# frozen_string_literal: true

require "test_helper"
require "openssl"

module Core
  module Reauthentication
    class IssueTest < ActiveSupport::TestCase
      setup do
        @user = core_users(:attendee)
        @session_jti = core_refresh_tokens(:attendee_web_token).jti
        @purpose = "attendee_export_request"
      end

      test "issues an opaque proof bound to the user, session, purpose, and password factor" do
        result = issue

        assert_predicate result, :success?, result.error&.message
        assert_kind_of String, result.value
        assert_operator result.value.length, :>, 0

        proof = latest_proof
        assert_equal @user.id, proof.user_id
        assert_equal @purpose, proof.purpose
        assert_equal "password", proof.factor_type
        assert_in_delta 5.minutes, proof.expires_at - proof.issued_at, 0.001
        assert_match(/\A[0-9a-f]{64}\z/, proof.session_jti_digest)
        assert_match(/\A[0-9a-f]{64}\z/, proof.token_digest)
        refute_equal result.value, proof.token_digest

        session_key = OpenSSL::HMAC.digest(
          "SHA256",
          Rails.application.secret_key_base,
          "core/reauthentication/session_jti"
        )
        proof_key = OpenSSL::HMAC.digest(
          "SHA256",
          Rails.application.secret_key_base,
          "core/reauthentication/proof/#{@purpose}"
        )
        assert_equal OpenSSL::HMAC.hexdigest("SHA256", session_key, @session_jti), proof.session_jti_digest
        assert_equal OpenSSL::HMAC.hexdigest("SHA256", proof_key, result.value), proof.token_digest
      end

      test "uses the supplied authentication session JTI when deriving the proof binding" do
        existing_ids = proofs.pluck(:id)
        first = issue(session_jti: "session-jti-one")
        first_proof = proofs.where.not(id: existing_ids).sole
        existing_ids = proofs.pluck(:id)
        second = issue(session_jti: "session-jti-two")
        second_proof = proofs.where.not(id: existing_ids).sole

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        refute_equal first_proof.session_jti_digest, second_proof.session_jti_digest
      end

      test "does not issue a proof for a bad password" do
        result = issue(password: "not-the-password")

        assert_predicate result, :failure?
        assert_empty proofs
      end

      test "does not issue a proof for a deactivated user" do
        @user.update!(deactivated_at: Time.current, deactivated_reason: "policy")

        result = issue

        assert_predicate result, :failure?
        assert_empty proofs
      end

      test "does not issue a proof for an unsupported purpose" do
        result = issue(purpose: "unrelated_action")

        assert_predicate result, :failure?
        assert_empty proofs
      end

      private

      def issue(password: "password123", purpose: @purpose, session_jti: @session_jti)
        Core::Reauthentication::Issue.call(
          user: @user,
          session_jti:,
          purpose:,
          password:
        )
      end

      def proofs
        Core::ReauthenticationProof.where(user_id: @user.id)
      end

      def latest_proof
        proofs.order(:issued_at).last
      end
    end
  end
end
