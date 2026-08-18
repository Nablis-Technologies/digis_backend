# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResalePoliciesControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Marketplace::ResaleReservationTestHelpers

    setup { setup_resale_reservation_context }

    test "an organizer delegates ticket-type resale policy changes to one command" do
      Marketplace::ConfigureTicketTypeResale.expects(:call).with(
        ticket_type: @ticket_type,
        actor: core_users(:super_admin),
        attributes: { "resale_enabled" => false },
        idempotency_key: "api-policy"
      ).returns(Core::BaseService::Result.success(@ticket_type))

      patch "/ticket_types/#{@ticket_type.id}/resale_policy",
            params: { resale_policy: { resale_enabled: false } },
            headers: headers_for(core_users(:super_admin)).merge("Idempotency-Key" => "api-policy"), as: :json

      assert_response :success
      assert_equal @ticket_type.id, response.parsed_body.dig("data", "id")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
