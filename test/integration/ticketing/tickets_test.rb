# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow }

    test "owner wallet includes the resale policy needed for pre-submit UX" do
      @product.ticket_type.update!(
        resale_enabled: true,
        resale_price_cap_type: "percentage",
        resale_percentage_cap_bps: 7_500,
        resale_cutoff_seconds_before_start: 3_600,
        max_completed_resales: 4
      )

      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      policy = response.parsed_body.fetch("data").sole.fetch("ticket_type")
      assert_equal true, policy.fetch("resale_enabled")
      assert_equal "percentage", policy.fetch("resale_price_cap_type")
      assert_equal 7_500, policy.fetch("resale_percentage_cap_bps")
      assert_equal 3_600, policy.fetch("resale_cutoff_seconds_before_start")
      assert_equal 4, policy.fetch("max_completed_resales")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
