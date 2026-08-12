# frozen_string_literal: true

require "test_helper"
require "digest"
require "ed25519"

module Ticketing
  module Contracts
    class CredentialContractTest < ActiveSupport::TestCase
      CONTRACT_PATH = Rails.root.join("test/fixtures/files/ticketing/credential_contract_v1.json")

      test "QR and attendee-index claims have identical decisions" do
        contract_cases.each do |entry|
          qr_result = Ticketing::Qr::Verifier.call(
            token: entry.fetch("token"), verify_keys: contract_verify_keys
          )
          assert_predicate qr_result, :success?, "#{entry.fetch("name")}: #{qr_result.error&.message}"

          qr_decision = Ticketing::Credentials::Validator.call(
            claims: qr_result.value,
            **contract_context(entry.fetch("context"))
          )
          index_decision = Ticketing::Credentials::Validator.call(
            claims: Ticketing::CredentialClaims.from_h(entry.fetch("claims")),
            **contract_context(entry.fetch("context"))
          )

          assert_equal entry.fetch("expected"), qr_decision.value.to_s, entry.fetch("name")
          assert_equal entry.fetch("expected"), index_decision.value.to_s, entry.fetch("name")
        end
      end

      test "credential claims reject missing and unexpected fields" do
        claims = contract_cases.first.fetch("claims")

        assert_raises(ArgumentError) do
          Ticketing::CredentialClaims.from_h(claims.except("exp"))
        end
        assert_raises(ArgumentError) do
          Ticketing::CredentialClaims.from_h(claims.merge("private_note" => "never"))
        end
        assert_raises(ArgumentError) do
          Ticketing::CredentialClaims.from_h(claims.merge("slots" => [ 1, 1 ]))
        end
      end

      test "validator rejects a credential shape that does not match its mode" do
        claims = Ticketing::CredentialClaims.from_h(contract_cases.first.fetch("claims"))
        malformed = Ticketing::CredentialClaims.new(**claims.to_h.merge(mode: "individual", entry_limit: 2))

        result = Ticketing::Credentials::Validator.call(
          claims: malformed,
          **contract_context(contract_cases.first.fetch("context"))
        )

        assert_predicate result, :success?
        assert_equal "invalid_claims", result.value.to_s
      end

      test "validator rejects a credential when one covered slot reached its use limit" do
        entry = contract_cases.first
        context = contract_context(entry.fetch("context")).merge(
          usage_limit: 1,
          active_use_counts: { "2" => 1 }
        )

        result = Ticketing::Credentials::Validator.call(
          claims: Ticketing::CredentialClaims.from_h(entry.fetch("claims")), **context
        )

        assert_predicate result, :success?
        assert_equal "already_used", result.value.to_s
      end

      private

      def contract_cases
        @contract_cases ||= JSON.parse(File.read(CONTRACT_PATH)).fetch("cases")
      end

      def contract_verify_keys
        @contract_verify_keys ||= {
          "v1" => Ed25519::SigningKey.new(Digest::SHA256.digest("ticketing-credential-contract-v1")).verify_key
        }
      end

      def contract_context(raw)
        raw.deep_symbolize_keys
      end
    end
  end
end
