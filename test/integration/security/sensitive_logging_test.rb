# frozen_string_literal: true

require "test_helper"

module Security
  class SensitiveLoggingTest < ActiveSupport::TestCase
    SENSITIVE_KEYS = %w[
      answer answer_ciphertext answers consent evidence_digest request_uuid
      email phone phone_ciphertext token_ciphertext tin_number
      business_license tin_certificate qr_token lookup_code credential
      account_token account_details holder_name_ciphertext account_label_ciphertext
      provider_payload webhook_body
    ].freeze

    test "filters sensitive domain fields from request parameters" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      payload = SENSITIVE_KEYS.index_with { |key| "secret-#{key}" }

      filtered = filter.filter(payload)

      SENSITIVE_KEYS.each do |key|
        assert_equal "[FILTERED]", filtered.fetch(key), "expected #{key} to be filtered"
      end
    end

    test "filters sensitive fields when nested in domain request payloads" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      payload = {
        organization: {
          tin_number: "TIN-PRIVATE",
          business_license: "license bytes"
        },
        payment: { provider_payload: { authorization: "gateway-secret" } },
        scanner: { credential: { qr_token: "qr-secret", lookup_code: "PNR12345" } }
      }

      filtered = filter.filter(payload)

      assert_equal "[FILTERED]", filtered.dig(:organization, :tin_number)
      assert_equal "[FILTERED]", filtered.dig(:organization, :business_license)
      assert_equal "[FILTERED]", filtered.dig(:payment, :provider_payload)
      assert_equal "[FILTERED]", filtered.dig(:scanner, :credential)
    end
  end
end
