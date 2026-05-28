module Core
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable
    include Core::Authorizable

    before_action :authenticate_user
    before_action :authorize_action!

    rescue_from ActiveRecord::RecordNotFound do |error|
      model_name = error.model&.constantize&.model_name&.human&.downcase || "resource"
      render_error(I18n.t(:"errors.not_found", model: model_name), status: :not_found)
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      render_error(errors: error.record.errors, status: :unprocessable_entity)
    end
  end
end
