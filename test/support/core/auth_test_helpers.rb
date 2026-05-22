module Core
  module AuthTestHelpers
    extend ActiveSupport::Concern

    included do
      setup :setup_auth_tokens
    end

    private

    def setup_auth_tokens
      @auth_admin_token = issue_token(:super_admin)
      @auth_user_token = issue_token(:attendee)
    end

    def admin_headers
      { "Authorization" => "Bearer #{@auth_admin_token}" }
    end

    def user_headers
      { "Authorization" => "Bearer #{@auth_user_token}" }
    end

    def issue_token(fixture_key)
      Core::TokenService.issue(Core::TokenService.access_token_payload(core_users(fixture_key)))
    end
  end
end
