# frozen_string_literal: true

require "test_helper"

module Orders
  class GiftPurchasesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Orders::GiftPurchaseTestHelpers
    include Ticketing::ConsentTestHelpers

    setup do
      setup_gift_purchase_context
    end

    test "resolves a gift bearer link without OTP and returns recipient-only form data" do
      _form, _version, question = create_required_gift_form

      post resolve_path,
           params: { gift: { token: @gift_token } },
           as: :json

      assert_response :ok
      data = response.parsed_body.fetch("data")
      assert_equal @gift_purchase.id, data.dig("gift", "id")
      assert_equal "A private gift note", data.dig("gift", "note")
      assert_equal question.key, data.dig("forms", 0, "questions", 0, "key")
      assert_nil data["ticket"]
      refute_includes response.body, @gift_phone
      refute_includes response.body, @gift_email
      refute_includes response.body, @gift_token
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "does not accept a bearer capability from query parameters" do
      query = URI.encode_www_form("gift[token]" => @gift_token)
      post "#{resolve_path}?#{query}", params: { gift: { token: "" } }, as: :json

      assert_response :bad_request, response.body
      assert_equal "invalid_request", response.parsed_body.fetch("code")
      refute_includes response.body, @gift_token
    end

    test "requires an idempotency key before a recipient can claim a gift" do
      _form, _version, question = create_required_gift_form

      post claim_path,
           params: {
             gift: {
               token: @gift_token,
               answers: [ { question_key: question.key, value: "Recipient" } ],
               consents: []
             }
           },
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_equal "ready", @gift_purchase.reload.status
      assert_empty Ticketing::Ticket.where(order_item_id: @gift_order_item.id)
    end

    test "recipient claims with the bearer link and required form answer without OTP" do
      _form, _version, question = create_required_gift_form

      post claim_path,
           params: {
             gift: {
               token: @gift_token,
               answers: [ { question_key: question.key, value: "Recipient" } ],
               consents: []
             }
           },
           headers: { "Idempotency-Key" => "gift-api-claim" },
           as: :json

      assert_response :ok
      data = response.parsed_body.fetch("data")
      assert_equal "claimed", data.dig("gift", "status")
      assert_equal @gift_purchase.recipient_user_id,
                   Ticketing::Ticket.find_by!(order_item_id: @gift_order_item.id, unit_number: 1).owner_user_id
      refute data.dig("ticket").key?("owner_user_id")
      assert_predicate data.dig("ticket", "qr_token"), :present?
      refute_includes response.body, @gift_token
      refute_includes response.body, @gift_phone
    end

    test "guest recipient can continue a pending admission-slot consent through the gift link" do
      _document, version = create_consent_document(scope: "admission_slot", required: true)

      post claim_path,
           params: { gift: { token: @gift_token, answers: [], consents: [] } },
           headers: { "Idempotency-Key" => "gift-api-slot-claim-start" },
           as: :json

      assert_response :ok
      pending = response.parsed_body.fetch("data")
      assert_equal "pending_recipient_consent", pending.dig("gift", "status")
      assert_nil pending.dig("ticket", "qr_token")
      assert_equal [ 1 ], pending.fetch("pending_consents").map { |item| item.fetch("admission_position") }
      ticket_id = pending.dig("ticket", "id")

      post claim_path,
           params: {
             gift: {
               token: @gift_token,
               answers: [],
               consents: [ {
                 consent_document_version_id: version.id,
                 package_unit_number: 1,
                 admission_position: 1,
                 request_uuid: SecureRandom.uuid,
                 acceptance_method: "checkbox",
                 content_sha256: version.content_sha256,
                 idempotency_key: "gift-api-slot-consent"
               } ]
             }
           },
           headers: { "Idempotency-Key" => "gift-api-slot-claim-finish" },
           as: :json

      assert_response :ok
      claimed = response.parsed_body.fetch("data")
      assert_equal "claimed", claimed.dig("gift", "status")
      assert_equal ticket_id, claimed.dig("ticket", "id")
      assert_predicate claimed.dig("ticket", "qr_token"), :present?
      assert_empty claimed.fetch("pending_consents")
      assert_equal 1, Ticketing::Ticket.where(order_item_id: @gift_order_item.id).count
    end

    test "continues slot consent without resubmitting an already accepted buyer consent" do
      _buyer_document, buyer_version = create_consent_document(scope: "buyer", required: true)
      _slot_document, slot_version = create_consent_document(scope: "admission_slot", required: true)

      post claim_path,
           params: {
             gift: {
               token: @gift_token,
               answers: [],
               consents: [ gift_consent_acceptance(buyer_version, "gift-buyer-consent") ]
             }
           },
           headers: { "Idempotency-Key" => "gift-mixed-consent-start" },
           as: :json

      assert_response :ok
      pending = response.parsed_body.fetch("data")
      assert_equal "pending_recipient_consent", pending.dig("gift", "status")
      assert_equal [ slot_version.id ], pending.fetch("pending_consents").map { |item| item.fetch("consent_document_version_id") }

      post claim_path,
           params: {
             gift: {
               token: @gift_token,
               answers: [],
               consents: [
                 gift_consent_acceptance(slot_version, "gift-slot-consent", package_unit_number: 1,
                   admission_position: 1)
               ]
             }
           },
           headers: { "Idempotency-Key" => "gift-mixed-consent-finish" },
           as: :json

      assert_response :ok
      claimed = response.parsed_body.fetch("data")
      assert_equal "claimed", claimed.dig("gift", "status")
      assert_empty claimed.fetch("pending_consents")
      assert_predicate claimed.dig("ticket", "qr_token"), :present?
    end

    test "an authenticated account other than the intended recipient cannot claim the link" do
      _form, _version, question = create_required_gift_form

      post claim_path,
           params: {
             gift: {
               token: @gift_token,
               answers: [ { question_key: question.key, value: "Recipient" } ],
               consents: []
             }
           },
           headers: user_headers.merge("Idempotency-Key" => "gift-api-wrong-account"),
           as: :json

      assert_response :forbidden
      assert_equal "gift_recipient_mismatch", response.parsed_body.fetch("code")
      assert_equal "ready", @gift_purchase.reload.status
    end

    test "payer can inspect only safe gift delivery status" do
      get "/orders/#{@gift_order.id}/gift_purchases", headers: user_headers, as: :json

      assert_response :ok
      assert_equal "no-store", response.headers.fetch("Cache-Control")
      data = response.parsed_body.fetch("data").sole
      assert_equal @gift_purchase.id, data.fetch("id")
      assert_nil data.fetch("line_id")
      assert_equal "ready", data.fetch("status")
      assert_equal "pending", data.fetch("delivery_status")
      refute_includes response.body, @gift_phone
      refute_includes response.body, @gift_email
      refute_includes response.body, @gift_token
      refute_includes response.body, @gift_purchase.note
    end

    test "payer resend is idempotent and does not return the bearer capability" do
      headers = user_headers.merge("Idempotency-Key" => "gift-resend-integration")

      post "/orders/#{@gift_order.id}/gift_purchases/#{@gift_purchase.id}/resend",
           headers:, as: :json
      assert_response :success
      assert_equal "no-store", response.headers.fetch("Cache-Control")
      refute_includes response.body, @gift_token
      refute_includes response.body, @gift_phone

      Prosopite.pause do
        post "/orders/#{@gift_order.id}/gift_purchases/#{@gift_purchase.id}/resend",
             headers:, as: :json
        assert_response :success
        refute_includes response.body, @gift_token
        refute_includes response.body, @gift_phone
      end

      assert_equal 1, @gift_purchase.reload.delivery_revision
      assert_equal 1, Core::OutboxEvent.where(
        event_type: "orders.gift_purchase.delivery_requested",
        aggregate_id: @gift_purchase.id
      ).count
    end

    test "another authenticated user cannot inspect or resend the payer gift" do
      get "/orders/#{@gift_order.id}/gift_purchases", headers: user_headers.merge(
        "Authorization" => "Bearer #{issue_token(:support)}"
      ), as: :json
      assert_response :forbidden

      post "/orders/#{@gift_order.id}/gift_purchases/#{@gift_purchase.id}/resend",
           headers: { "Authorization" => "Bearer #{issue_token(:support)}", "Idempotency-Key" => "outsider-gift" },
           as: :json
      assert_response :forbidden
      assert_equal 0, @gift_purchase.reload.delivery_revision
    end

    test "payer resend requires an idempotency key" do
      post "/orders/#{@gift_order.id}/gift_purchases/#{@gift_purchase.id}/resend",
           headers: user_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_equal 0, @gift_purchase.delivery_revision
    end

    private

    def resolve_path
      "/public/gift_purchases/#{@gift_purchase.id}/resolve"
    end

    def claim_path
      "/public/gift_purchases/#{@gift_purchase.id}/claim"
    end

    def gift_consent_acceptance(version, idempotency_key, **coordinates)
      {
        consent_document_version_id: version.id,
        request_uuid: SecureRandom.uuid,
        acceptance_method: "checkbox",
        content_sha256: version.content_sha256,
        idempotency_key:,
        **coordinates
      }
    end
  end
end
