# frozen_string_literal: true

require "test_helper"

module Catalog
  class PromotionsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Festival Pass",
        type: "merchandise",
        status: "active",
        inventory_mode: "unlimited"
      )
      @promotion = Catalog::Promotion.create!(
        event: @event,
        name: "Opening discount",
        type: "percentage",
        percentage_basis_points: 1_000,
        currency: "ETB",
        status: "active",
        per_user_limit: 1
      )
      @code = Catalog::PromotionCode.create!(
        promotion: @promotion,
        code: "OPENING10",
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: "OPENING10"),
        redemption_limit: 250
      )
    end

    test "owner can create and update a draft promotion" do
      payload = {
        event_id: @event.id,
        name: "Draft discount",
        type: "fixed",
        fixed_amount_minor: 500,
        currency: "ETB",
        product_ids: [ @product.id ]
      }

      post "/catalog/promotions",
           params: payload,
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-create"),
           as: :json

      assert_response :created
      promotion_id = response.parsed_body.dig("data", "id")
      assert_equal "draft", response.parsed_body.dig("data", "status")

      patch "/catalog/promotions/#{promotion_id}",
            params: { name: "Updated draft" },
            headers: owner_headers.merge("Idempotency-Key" => "http-promotion-update"),
            as: :json

      assert_response :success
      assert_equal "Updated draft", response.parsed_body.dig("data", "name")
    end

    test "owner can create a successor promotion through HTTP" do
      post "/catalog/promotions",
           params: {
             event_id: @event.id,
             supersedes_promotion_id: @promotion.id,
             version: 999,
             name: "Successor discount",
             type: "fixed",
             fixed_amount_minor: 500,
             currency: "ETB"
           },
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-successor-create"),
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal @promotion.id, data["supersedes_promotion_id"]
      assert_equal 2, data["version"]
    end

    test "promotion create rejects scalar product ids" do
      post "/catalog/promotions",
           params: {
             event_id: @event.id,
             name: "Invalid scope input",
             type: "fixed",
             fixed_amount_minor: 500,
             currency: "ETB",
             product_ids: "not-an-array"
           },
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-scalar-product-id"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal I18n.t("catalog.promotion.errors.invalid_product_ids"), response.parsed_body["error"]
    end

    test "owner can list and show promotions without exposing code secrets" do
      get "/catalog/promotions?event_id=#{@event.id}", headers: owner_headers, as: :json

      assert_response :success
      assert_equal @promotion.id, response.parsed_body.dig("data", 0, "id")

      get "/catalog/promotions/#{@promotion.id}", headers: owner_headers, as: :json

      assert_response :success
      refute_includes response.body, "OPENING10"
      refute_includes response.body, "code_digest"
      refute_includes response.body, "code_ciphertext"
    end

    test "attendee cannot show an organizer promotion" do
      get "/catalog/promotions/#{@promotion.id}", headers: user_headers, as: :json

      assert_response :not_found
    end

    test "attendee cannot show an organizer promotion code" do
      get "/catalog/promotion_codes/#{@code.id}", headers: user_headers, as: :json

      assert_response :not_found
    end

    test "owner can delete a draft promotion and replay the delete" do
      draft = Catalog::Promotion.create!(
        event: @event,
        name: "Discardable draft",
        type: "fixed",
        fixed_amount_minor: 500,
        currency: "ETB",
        status: "draft",
        per_user_limit: 1
      )
      headers = owner_headers.merge("Idempotency-Key" => "http-promotion-delete")

      delete "/catalog/promotions/#{draft.id}", headers:, as: :json
      assert_response :success
      assert_not Catalog::Promotion.exists?(draft.id)

      delete "/catalog/promotions/#{draft.id}", headers:, as: :json
      assert_response :success
    end

    test "missing idempotency key returns bad request" do
      post "/catalog/promotions",
           params: {
             event_id: @event.id,
             name: "Draft discount",
             type: "fixed",
             fixed_amount_minor: 500,
             currency: "ETB"
           },
           headers: owner_headers,
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "attendee cannot manage promotions" do
      post "/catalog/promotions",
           params: {
             event_id: @event.id,
             name: "Forbidden discount",
             type: "fixed",
             fixed_amount_minor: 500,
             currency: "ETB"
           },
           headers: user_headers.merge("Idempotency-Key" => "http-promotion-forbidden"),
           as: :json

      assert_response :forbidden
    end

    test "owner can publish and disable a promotion" do
      draft = Catalog::Promotion.create!(
        event: @event,
        name: "Draft lifecycle",
        type: "fixed",
        fixed_amount_minor: 500,
        currency: "ETB",
        status: "draft",
        per_user_limit: 1
      )

      post "/catalog/promotions/#{draft.id}/publish",
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-publish"),
           as: :json
      assert_response :success
      assert_equal "active", response.parsed_body.dig("data", "status")

      post "/catalog/promotions/#{draft.id}/disable",
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-disable"),
           as: :json
      assert_response :success
      assert_equal "disabled", response.parsed_body.dig("data", "status")
    end

    test "code reads hide plaintext and reveal returns it explicitly" do
      get "/catalog/promotion_codes/#{@code.id}", headers: owner_headers, as: :json

      assert_response :success
      body = response.body
      refute_includes body, "OPENING10"
      refute_includes body, "code_digest"
      refute_includes body, "code_ciphertext"

      post "/catalog/promotion_codes/#{@code.id}/reveal",
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-reveal"),
           as: :json

      assert_response :success
      assert_equal "OPENING10", response.parsed_body.dig("data", "code")
    end

    test "owner can create a code and receives plaintext only in the create response" do
      post "/catalog/promotion_codes",
           params: {
             promotion_id: @promotion.id,
             code: " launch10 ",
             label: "Launch discount",
             redemption_limit: 25,
             active: true
           },
           headers: owner_headers.merge("Idempotency-Key" => "http-promotion-code-create"),
           as: :json

      assert_response :created
      assert_equal "LAUNCH10", response.parsed_body.dig("data", "code")
      code_id = response.parsed_body.dig("data", "id")

      get "/catalog/promotion_codes/#{code_id}", headers: owner_headers, as: :json

      assert_response :success
      refute_includes response.body, "LAUNCH10"
      refute_includes response.body, "code_digest"
      refute_includes response.body, "code_ciphertext"
    end

    test "owner can request a promotion quote" do
      post "/catalog/promotions/#{@promotion.id}/quote",
           params: {
             code: " opening10 ",
             eligible_product_ids: [ @product.id ],
             eligible_subtotal_minor: 10_000,
             charge_currency: "ETB"
           },
           headers: owner_headers,
           as: :json

      assert_response :success
      assert_equal 1_000, response.parsed_body.dig("data", "discount_minor")
      assert_equal @code.id, response.parsed_body.dig("data", "promotion_code_id")
      assert_equal 250, response.parsed_body.dig("data", "code_redemption_limit")
    end
  end
end
