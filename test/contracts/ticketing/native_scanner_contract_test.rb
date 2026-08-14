# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "test_helper"

module Ticketing
  module Contracts
    class NativeScannerContractTest < ActiveSupport::TestCase
      CONTRACT_PATH = Rails.root.join("test/fixtures/files/ticketing/credential_contract_v1.json")
      SYNC_CONTRACT_PATH = Rails.root.join("test/fixtures/files/ticketing/scanner_sync_contract_v1.json")

      test "the native validator corpus matches the shared Rails validator" do
        contract = load_contract

        assert_equal Ticketing::Credentials::Validator::DECISIONS,
          contract.fetch("validator_decisions")
        assert_equal contract.fetch("claim_keys").sort, Ticketing::CredentialClaims.members.map(&:to_s).sort

        contract.fetch("cases").each do |entry|
          result = Ticketing::Credentials::Validator.call(
            claims: Ticketing::CredentialClaims.from_h(entry.fetch("claims")),
            **entry.fetch("context").deep_symbolize_keys
          )

          assert_predicate result, :success?, entry.fetch("name")
          assert_equal entry.fetch("expected"), result.value.to_s, entry.fetch("name")
        end
      end

      test "signed envelope outcomes are explicit and stable" do
        contract = load_contract
        entry = contract.fetch("cases").first
        payload = entry.fetch("claims")

        outcomes = {
          "invalid signature" => Ticketing::Qr::Verifier.call(
            token: encoded_envelope(payload.merge("sig" => "invalid")),
            verify_keys: contract_verify_keys
          ),
          "unknown key" => Ticketing::Qr::Verifier.call(
            token: signed_token(payload.merge("kid" => "unknown")),
            verify_keys: contract_verify_keys
          ),
          "expired" => Ticketing::Qr::Verifier.call(
            token: entry.fetch("token"), now: Time.at(payload.fetch("exp") + 1),
            verify_keys: contract_verify_keys
          ),
          "invalid claims" => Ticketing::Qr::Verifier.call(
            token: signed_token(payload.except("exp")), verify_keys: contract_verify_keys
          )
        }

        outcomes.each do |name, result|
          assert_predicate result, :failure?, name
          assert_equal contract.fetch("verifier_decisions").fetch(name), result.error.code, name
        end
      end

      test "admission and stale-projection vocabularies are shared with native clients" do
        contract = load_contract

        assert_equal Ticketing::CheckinLog::LOOKUP_METHODS, contract.fetch("lookup_methods")
        assert_equal Ticketing::CheckinLog::IDENTITY_RESULTS, contract.fetch("identity_check_results")
        assert_equal Ticketing::CheckinLog::RESULTS, contract.fetch("checkin_results")

        contract.fetch("stale_projection_cases").each do |stale_case|
          base = contract.fetch("cases").find { |entry| entry.fetch("name") == stale_case.fetch("base_case") }
          refute_nil base, stale_case.fetch("name")

          context = base.fetch("context").deep_merge(stale_case.fetch("context")).deep_symbolize_keys
          result = Ticketing::Credentials::Validator.call(
            claims: Ticketing::CredentialClaims.from_h(base.fetch("claims")), **context
          )

          assert_predicate result, :success?, stale_case.fetch("name")
          assert_equal stale_case.fetch("expected"), result.value.to_s, stale_case.fetch("name")
        end
      end

      test "offline replay and conflict semantics are explicit" do
        contract = load_sync_contract.fetch("offline_behavior")

        assert_equal 500, Ticketing::ScannerSync::ProcessUpload::MAX_SCANS
        assert_equal "single_transaction", contract.fetch("apply_transaction")
        assert_equal "last", contract.fetch("cursor_commit_position")
        assert_equal "return_exact_stored_snapshot", contract.dig("replay", "upload_id")
        assert_equal "return_original_scan_result", contract.dig("replay", "scan_id")
        assert_equal "duplicate", contract.dig("disconnected_conflict", "server_result")
        assert_equal "first_authoritative_server_use",
          contract.dig("disconnected_conflict", "winner")
      end

      private

      def load_contract
        @contract ||= JSON.parse(File.read(CONTRACT_PATH))
      end

      def load_sync_contract
        @sync_contract ||= JSON.parse(File.read(SYNC_CONTRACT_PATH))
      end

      def contract_verify_keys
        @contract_verify_keys ||= {
          "v1" => Ed25519::SigningKey.new(
            Digest::SHA256.digest("ticketing-credential-contract-v1")
          ).verify_key
        }
      end

      def contract_signing_key
        @contract_signing_key ||= Ed25519::SigningKey.new(
          Digest::SHA256.digest("ticketing-credential-contract-v1")
        )
      end

      def signed_token(payload)
        envelope = payload.stringify_keys
        signature = contract_signing_key.sign(Ticketing::Qr::Signer.canonical_json(envelope))
        encoded_envelope(envelope.merge("sig" => Base64.strict_encode64(signature)))
      end

      def encoded_envelope(envelope)
        Base64.urlsafe_encode64(JSON.generate(envelope), padding: false)
      end
    end
  end
end
