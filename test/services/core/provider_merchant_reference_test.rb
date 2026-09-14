# frozen_string_literal: true

require "test_helper"

module Core
  class ProviderMerchantReferenceTest < ActiveSupport::TestCase
    test "returns a deterministic provider-safe reference with enough entropy" do
      arguments = {
        provider: "chapa",
        subject_id: "order-123",
        idempotency_key: "DIGIS_DIAG_20260913182310",
        attempt_number: 1
      }

      first = ProviderMerchantReference.call(**arguments)
      replay = ProviderMerchantReference.call(**arguments)
      different_attempt = ProviderMerchantReference.call(**arguments.merge(attempt_number: 2))

      assert_equal 20, first.length
      assert_match(/\A[0-9a-f]{20}\z/, first)
      assert_equal first, replay
      refute_equal first, different_attempt
    end
  end
end
