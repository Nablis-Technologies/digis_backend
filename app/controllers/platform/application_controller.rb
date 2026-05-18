module Platform
  class ApplicationController < ::ApplicationController
    include Platform::JsonResponse
    include Platform::Authenticatable
    include Platform::TokenAuthenticatable
    include Platform::Authorizable

    before_action :authenticate_user
    before_action :authorize_action!
  end
end
