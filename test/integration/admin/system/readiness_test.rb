# frozen_string_literal: true

require "test_helper"

class AdminSystemReadinessTest < ActionDispatch::IntegrationTest
  include Core::AuthorizationTestHelpers

  test "keeps process liveness separate from authenticated readiness" do
    get "/up"
    assert_response :success

    get "/admin/system/readiness", as: :json
    assert_response :unauthorized
  end

  test "requires platform-admin authority" do
    get "/admin/system/readiness", headers: token_headers_for(:attendee), as: :json
    assert_response :forbidden

    get "/admin/system/readiness", headers: token_headers_for(:core_admin), as: :json
    assert_response :success
  end

  test "returns only status and component names" do
    get "/admin/system/readiness", headers: admin_headers, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.fetch("success")
    data = body.fetch("data")
    assert_includes %w[ok degraded], data.fetch("status")
    assert_equal %w[database encryption outbox queue storage], data.fetch("components").keys.sort
    refute_match(/password|secret|host|provider|exception|queue_contents/i, body.to_s)
  end
end
