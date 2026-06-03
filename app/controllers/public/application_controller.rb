module Public
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable
    include Core::Pagination

    rescue_from ActiveRecord::RecordNotFound do |error|
      model_name = error.model&.constantize&.model_name&.human&.downcase || "resource"
      render_error(I18n.t(:"errors.not_found", model: model_name), status: :not_found)
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      render_error(errors: error.record.errors, status: :unprocessable_entity)
    end

    private

    def policy_for_data(data)
      nil
    end
  end
end
