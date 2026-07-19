# frozen_string_literal: true

module Core
  module CommandResponse
    extend ActiveSupport::Concern

    def render_service_result(result, success_status: :ok, serializer_options: {})
      return render_success(data: result.value, status: success_status, serializer_options:) if result.success?

      render_business_error(result.error)
    end

    private

    def render_business_error(error)
      render_error(
        error.message,
        status: error.status,
        code: error.code,
        errors: error.errors,
        meta: error.meta
      )
    end
  end
end
