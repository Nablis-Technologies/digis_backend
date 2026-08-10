# frozen_string_literal: true

require "test_helper"

module Core
  module Reauthentication
    class ConsumeTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      setup do
        @user = core_users(:attendee)
        @session_jti = core_refresh_tokens(:attendee_web_token).jti
        @purpose = "attendee_export_request"
      end

      test "consumes a valid proof only once" do
        raw_proof = issue

        first = consume(raw_proof:)
        second = consume(raw_proof:)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal invalid_signature(second), invalid_signature(consume(raw_proof: SecureRandom.hex(32)))
        assert_equal 1, proofs.where.not(consumed_at: nil).count
      end

      test "returns the same controlled failure for every invalid proof condition" do
        invalid_results = [
          consume(raw_proof: nil),
          consume(raw_proof: "not-a-proof"),
          consume(raw_proof: issue, purpose: "attendee_export_download"),
          consume(raw_proof: issue, session_jti: "another-session-jti")
        ]

        existing_ids = proofs.pluck(:id)
        expired_proof = issue
        proof = proofs.where.not(id: existing_ids).sole
        travel_to proof.expires_at + 1.second do
          invalid_results << consume(raw_proof: expired_proof)
        end

        assert invalid_results.all?(&:failure?)
        assert_equal 1, invalid_results.map { |result| invalid_signature(result) }.uniq.length
      end

      test "rejects a proof after the user is deactivated" do
        raw_proof = issue
        @user.update!(deactivated_at: Time.current, deactivated_reason: "policy")

        result = consume(raw_proof:)

        assert_predicate result, :failure?
        assert_equal "invalid_reauthentication_proof", result.error.code
      end

      test "rechecks persisted account state before consuming a proof" do
        raw_proof = issue
        Core::User.where(id: @user.id).update_all(
          deactivated_at: Time.current,
          deactivated_reason: "policy"
        )

        result = consume(raw_proof:)

        assert_predicate result, :failure?
        assert_equal "invalid_reauthentication_proof", result.error.code
        assert_nil proofs.pick(:consumed_at)
      end

      test "rejects a proof after its authentication session is revoked" do
        raw_proof = issue
        core_refresh_tokens(:attendee_web_token).revoke!

        result = consume(raw_proof:)

        assert_predicate result, :failure?
        assert_equal "invalid_reauthentication_proof", result.error.code
      end

      test "rejects a proof with the wrong purpose" do
        result = consume(raw_proof: issue, purpose: "attendee_export_download")

        assert_predicate result, :failure?
        assert_equal "invalid_reauthentication_proof", result.error.code
      end

      private

      def issue(purpose: @purpose, session_jti: @session_jti)
        result = Core::Reauthentication::Issue.call(
          user: @user,
          session_jti:,
          purpose:,
          password: "password123"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def consume(raw_proof:, purpose: @purpose, session_jti: @session_jti)
        Core::Reauthentication::Consume.call(
          user: @user,
          session_jti:,
          purpose:,
          raw_proof:
        )
      end

      def proofs
        Core::ReauthenticationProof.where(user_id: @user.id)
      end

      def invalid_signature(result)
        error = result.error
        [ error.class.name, error.respond_to?(:code) ? error.code : nil, error.message ]
      end
    end

    class ConsumeConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @user = core_users(:attendee)
        @refresh_token = Core::RefreshToken.generate(@user, ActionDispatch::TestRequest.create)
        @session_jti = @refresh_token.jti
        result = Core::Reauthentication::Issue.call(
          user: @user,
          session_jti: @session_jti,
          purpose: "attendee_export_request",
          password: "password123"
        )
        assert_predicate result, :success?, result.error&.message
        @raw_proof = result.value
        @proof_id = Core::ReauthenticationProof.where(user_id: @user.id).order(:issued_at).last.id
      end

      teardown do
        Core::ReauthenticationProof.where(id: @proof_id).delete_all if defined?(Core::ReauthenticationProof)
        @refresh_token&.delete
      end

      test "two independent connections can consume a proof only once" do
        ready = Queue.new
        start = Queue.new
        workers = 2.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              ready << true
              start.pop
              Core::Reauthentication::Consume.call(
                user: Core::User.find(@user.id),
                session_jti: @session_jti,
                purpose: "attendee_export_request",
                raw_proof: @raw_proof
              )
            end
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        results = workers.map(&:value)

        assert results.all? { |result| result.is_a?(Core::BaseService::Result) }, results.inspect
        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count(&:failure?)
        assert_equal 1, Core::ReauthenticationProof.where(id: @proof_id).where.not(consumed_at: nil).count
      end
    end
  end
end
