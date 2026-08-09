# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PurchaseLimitOverridesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @actor = core_users(:attendee)
      @ticket_type = create_ticket_type
      @registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: @actor,
        created_by: @actor,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
    end

    test "platform admin creates an idempotent purchase-limit override" do
      headers = admin_headers.merge("Idempotency-Key" => "http-limit-override")
      payload = { additional_packages: 2, reason_code: "accessibility" }

      assert_difference("Ticketing::PurchaseLimitOverride.count", 1) do
        post "/registrations/#{@registration.id}/purchase_limit_override", params: payload, headers:, as: :json
      end
      assert_response :created

      assert_no_difference("Ticketing::PurchaseLimitOverride.count") do
        post "/registrations/#{@registration.id}/purchase_limit_override", params: payload, headers:, as: :json
      end
      assert_response :success
    end

    test "missing idempotency key returns bad request" do
      post "/registrations/#{@registration.id}/purchase_limit_override",
        params: { additional_packages: 1, reason_code: "accessibility" },
        headers: admin_headers,
        as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
    end

    test "attendee cannot grant a purchase-limit override" do
      post "/registrations/#{@registration.id}/purchase_limit_override",
        params: { additional_packages: 1, reason_code: "accessibility" },
        headers: user_headers.merge("Idempotency-Key" => "http-limit-forbidden"),
        as: :json

      assert_response :forbidden
      assert_empty Ticketing::PurchaseLimitOverride.all
    end

    private

    def create_ticket_type
      Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Override ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1, max_packages_per_user: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
    end
  end
end
