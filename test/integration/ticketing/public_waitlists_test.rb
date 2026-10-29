# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PublicWaitlistsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update!(status: "published")
      @actor = core_users(:super_admin)
      @delivered_codes = []
      @previous_sender = Rails.application.config.x.phone_verification_sender
      Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
        @delivered_codes << { phone:, code:, challenge_id: challenge.id }
      end
    end

    teardown do
      Rails.application.config.x.phone_verification_sender = @previous_sender
    end

    test "public waitlist requires an idempotency key" do
      product = create_ticket_product(name: "Sold-out public offer")

      post waitlist_path(product), params: { waitlist: { quantity: 1 } }, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "authenticated attendee can join a sold-out offer" do
      product = create_ticket_product(name: "Sold-out attendee offer")

      post waitlist_path(product),
           params: { waitlist: { quantity: 1 } },
           headers: user_headers.merge("Idempotency-Key" => "public-waitlist-attendee"),
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "waitlisted", data.dig("next_action", "type")
      assert_equal "waitlisted", data.dig("registration", "status")
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "available offer cannot be joined and does not create a registration" do
      product = create_ticket_product(name: "Available attendee offer", sold_out: false)

      post waitlist_path(product),
           params: { waitlist: { quantity: 1 } },
           headers: user_headers.merge("Idempotency-Key" => "public-waitlist-available"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "waitlist_not_sold_out", response.parsed_body.fetch("code")
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
    end

    test "guest verifies phone before joining a paid waitlist offer" do
      product = create_ticket_product(name: "Guest paid offer")
      phone = "+251911000111"

      post otp_path(product),
           params: { waitlist: { phone:, quantity: 1 } },
           headers: { "Idempotency-Key" => "public-waitlist-otp" },
           as: :json

      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")
      assert_equal "no-store", response.headers.fetch("Cache-Control")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @delivered_codes.sole.fetch(:code) },
           headers: { "Idempotency-Key" => "public-waitlist-verify" },
           as: :json
      assert_response :success
      verification_token = response.parsed_body.dig("data", "verification_token")

      post waitlist_path(product),
           params: { waitlist: { phone:, verification_token:, quantity: 1 } },
           headers: { "Idempotency-Key" => "public-waitlist-guest" },
           as: :json

      assert_response :created
      assert_equal "waitlisted", response.parsed_body.dig("data", "registration", "status")
      assert_equal "waitlisted", response.parsed_body.dig("data", "next_action", "type")
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "invalid bearer token never falls back to guest waitlist enrollment" do
      product = create_ticket_product(name: "Invalid bearer offer")

      post waitlist_path(product),
           params: { waitlist: { quantity: 1 } },
           headers: {
             "Authorization" => "Bearer invalid-token",
             "Idempotency-Key" => "public-waitlist-invalid-bearer"
           },
           as: :json

      assert_response :unauthorized
      assert_equal "authentication_required", response.parsed_body.fetch("code")
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
    end

    private

    def waitlist_path(product)
      "/public/events/#{@event.slug}/admission_offers/#{product.id}/waitlist"
    end

    def otp_path(product)
      "#{waitlist_path(product)}/request_otp"
    end

    def create_ticket_product(name:, sold_out: true, approval_mode: "automatic")
      result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @actor,
        product_attributes: { name:, type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode:, date_selection: "fixed", admissions_per_unit: 1,
          waitlist_enabled: true
        },
        price_attributes: { currency: "ETB", amount_minor: 1_500, active_from: 1.minute.ago },
        inventory_configuration: { mode: "event_wide", capacity: 1 }
      )
      assert_predicate result, :success?, result.error&.message
      activated = Catalog::Products::Activate.call(product: result.value, actor: @actor)
      assert_predicate activated, :success?, activated.error&.message
      product = activated.value
      product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1) if sold_out
      product
    end
  end
end
