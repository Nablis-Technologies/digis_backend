module Core
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::CommandResponse
    include Core::Authenticatable
    include Core::Authorizable
    include Core::IdempotencyKeyResolver

    before_action :authenticate_user
    before_action :authorize_action!

    include Core::RescuableErrors
  end
end
