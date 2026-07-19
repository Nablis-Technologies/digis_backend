# frozen_string_literal: true

require "test_helper"

class CommandResponseProbeController < Core::ApplicationController
  skip_before_action :authenticate_user
  skip_authorization

  def success
    render_service_result Core::BaseService::Result.success({ id: "result-id" }), success_status: :created
  end

  def failure
    error = Core::BusinessError.new("Unavailable", code: "unavailable", status: :conflict)
    render_service_result Core::BaseService::Result.failure(error)
  end
end

class Core::CommandResponseTest < ActionController::TestCase
  tests CommandResponseProbeController

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "success", to: "command_response_probe#success"
      get "failure", to: "command_response_probe#failure"
    end
  end

  test "renders a successful command value" do
    get :success

    assert_response :created
    assert_equal true, response.parsed_body.fetch("success")
    assert_equal "result-id", response.parsed_body.dig("data", "id")
  end

  test "renders the typed failure status and code" do
    get :failure

    assert_response :conflict
    assert_equal false, response.parsed_body.fetch("success")
    assert_equal "unavailable", response.parsed_body.fetch("code")
  end
end
