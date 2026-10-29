# frozen_string_literal: true

require "test_helper"

module Orders
  class PaymentCallbacksControllerTest < ActionDispatch::IntegrationTest
    test "accepts a verified provider callback without authentication" do
      event = Struct.new(:id, :payment_id, :status).new("event-id", "payment-id", "received")
      result = Core::BaseService::Result.success(event)
      Orders::RecordPaymentCallback.expects(:call).with(
        provider: "chapa", transaction_reference: "tx-ref", provider_reference: "ref-1",
        callback_status: "success"
      ).returns(result)

      get "/payments/chapa/callback", params: {
        trx_ref: "tx-ref", ref_id: "ref-1", status: "success"
      }

      assert_response :accepted
      assert_equal true, response.parsed_body.fetch("success")
      assert_equal "received", response.parsed_body.dig("data", "status")
      assert_equal "payment-id", response.parsed_body.dig("data", "payment_id")
    end

    test "returns a localized error when the provider is missing" do
      get "/payments/chapa/callback"

      assert_response :bad_request
      assert_equal "invalid_callback", response.parsed_body.fetch("code")
    end

    test "accepts V2 merchant and Chapa reference callback parameters" do
      event = Struct.new(:id, :payment_id, :status).new("event-id", "payment-id", "received")
      result = Core::BaseService::Result.success(event)
      Orders::RecordPaymentCallback.expects(:call).with(
        provider: "chapa", transaction_reference: "merchant-ref", provider_reference: "chapa-ref",
        callback_status: "success"
      ).returns(result)

      get "/payments/chapa/callback", params: {
        merchant_reference: "merchant-ref", chapa_reference: "chapa-ref", status: "success"
      }

      assert_response :accepted
    end
  end
end
