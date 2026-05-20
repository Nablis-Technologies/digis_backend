module Core
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable
    include Core::TokenAuthenticatable
    include Core::Authorizable

    before_action :authenticate_user
    before_action :authorize_action!
  end
end
