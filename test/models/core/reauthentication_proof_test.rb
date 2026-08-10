# frozen_string_literal: true

require "test_helper"

module Core
  class ReauthenticationProofTest < ActiveSupport::TestCase
    setup do
      @issued_at = Time.current.change(usec: 0)
      @attributes = {
        user: core_users(:attendee),
        session_jti_digest: SecureRandom.hex(32),
        purpose: "attendee_export_request",
        factor_type: "password",
        token_digest: SecureRandom.hex(32),
        issued_at: @issued_at,
        expires_at: @issued_at + 5.minutes
      }
    end

    test "accepts a proof with the launch purpose, factor, and exact lifetime" do
      proof = Core::ReauthenticationProof.new(@attributes)

      assert_predicate proof, :valid?
      assert_equal @issued_at + 5.minutes, proof.expires_at
    end

    test "requires an authenticated user" do
      proof = Core::ReauthenticationProof.new(@attributes.merge(user: nil))

      assert_not proof.valid?
      assert proof.errors.key?(:user)
    end

    test "rejects purposes outside the allowlist" do
      proof = Core::ReauthenticationProof.new(@attributes.merge(purpose: "other"))

      assert_not proof.valid?
      assert proof.errors.key?(:purpose)
    end

    test "rejects factors outside the allowlist" do
      proof = Core::ReauthenticationProof.new(@attributes.merge(factor_type: "otp"))

      assert_not proof.valid?
      assert proof.errors.key?(:factor_type)
    end

    test "requires lowercase 64-character hexadecimal HMAC-shaped digests" do
      proof = Core::ReauthenticationProof.new(
        @attributes.merge(session_jti_digest: "g" * 64, token_digest: "a" * 63)
      )

      assert_not proof.valid?
      assert proof.errors.key?(:session_jti_digest)
      assert proof.errors.key?(:token_digest)
    end

    test "rejects a proof lifetime longer than five minutes" do
      proof = Core::ReauthenticationProof.new(@attributes.merge(expires_at: @issued_at + 5.minutes + 1.second))

      assert_not proof.valid?
      assert proof.errors.key?(:expires_at)
    end

    test "requires consumed_at to be at or after issued_at" do
      proof = Core::ReauthenticationProof.new(@attributes.merge(consumed_at: @issued_at - 1.second))

      assert_not proof.valid?
      assert proof.errors.key?(:consumed_at)
    end

    test "enforces unique token digests" do
      first = Core::ReauthenticationProof.create!(@attributes)
      duplicate = Core::ReauthenticationProof.new(
        @attributes.merge(session_jti_digest: SecureRandom.hex(32))
      )

      assert_not duplicate.valid?
      assert duplicate.errors.key?(:token_digest)
      assert first.persisted?
    end

    test "database constraints protect persisted proof invariants" do
      proof = Core::ReauthenticationProof.create!(@attributes)

      assert_database_rejects { update_proof(proof, purpose: "other") }
      assert_database_rejects { update_proof(proof, factor_type: "otp") }
      assert_database_rejects { update_proof(proof, session_jti_digest: "g" * 64) }
      assert_database_rejects { update_proof(proof, token_digest: "g" * 64) }
      assert_database_rejects { update_proof(proof, expires_at: @issued_at + 4.minutes) }
      assert_database_rejects { update_proof(proof, consumed_at: @issued_at - 1.second) }
      assert_database_rejects do
        Core::ReauthenticationProof.insert_all!([ database_attributes(user_id: SecureRandom.uuid) ])
      end
      assert_database_rejects do
        Core::ReauthenticationProof.insert_all!([ database_attributes(session_jti_digest: SecureRandom.hex(32)) ])
      end
    end

    private

    def update_proof(proof, attributes)
      Core::ReauthenticationProof.where(id: proof.id).update_all(attributes)
    end

    def database_attributes(overrides = {})
      @attributes.except(:user).merge(
        id: SecureRandom.uuid,
        user_id: @attributes[:user].id,
        created_at: Time.current,
        updated_at: Time.current
      ).merge(overrides)
    end

    def assert_database_rejects(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        Core::ReauthenticationProof.transaction(requires_new: true, &block)
      end
    end
  end
end
