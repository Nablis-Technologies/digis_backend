module Core
  module AuthorizationTestHelpers
    extend ActiveSupport::Concern

    included do
      include Core::AuthTestHelpers
    end

    private

    def assert_permitted(fixture_key, action, path, record: nil, params: nil)
      headers = token_headers_for(fixture_key)
      perform_request(action, path, record: record, params: params, headers: headers)
      assert_response :success
      parse_response
    end

    def assert_forbidden(fixture_key, action, path, record: nil, params: nil)
      headers = token_headers_for(fixture_key)
      perform_request(action, path, record: record, params: params, headers: headers)
      assert_response :forbidden
    end

    def assert_unauthorized(action, path, record: nil, params: nil)
      perform_request(action, path, record: record, params: params, headers: {})
      assert_response :unauthorized
    end

    def perform_request(action, path, record: nil, params: nil, headers:)
      case action
      when :index then get path, headers: headers, as: :json
      when :show then get "#{path}/#{record.id}", headers: headers, as: :json
      when :create then post path, params: params, headers: headers, as: :json
      when :update then patch "#{path}/#{record.id}", params: params, headers: headers, as: :json
      when :destroy then delete "#{path}/#{record.id}", headers: headers, as: :json
      end
    end

    def parse_response
      JSON.parse(response.body)
    end

    def token_headers_for(fixture_key)
      token = Core::TokenService.issue(Core::TokenService.access_token_payload(core_users(fixture_key)))
      { "Authorization" => "Bearer #{token}" }
    end
  end
end
