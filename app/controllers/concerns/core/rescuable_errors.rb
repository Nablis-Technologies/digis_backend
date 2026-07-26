# frozen_string_literal: true

module Core
  module RescuableErrors
    extend ActiveSupport::Concern

    included do
      rescue_from ActiveRecord::RecordNotFound do |error|
        model_name = error.model&.constantize&.model_name&.human&.downcase || "resource"
        render_error(I18n.t(:"errors.not_found", model: model_name), status: :not_found)
      end

      rescue_from ActiveRecord::RecordInvalid do |error|
        render_error(errors: error.record.errors, status: :unprocessable_entity)
      end

      rescue_from ActiveRecord::RecordNotUnique do |error|
        render_error(I18n.t(:"errors.not_unique"), status: :unprocessable_entity)
      end

      rescue_from ActiveRecord::StatementInvalid do |error|
        render_error(I18n.t(:"errors.statement_invalid"), status: :unprocessable_entity)
      end

      rescue_from ActiveRecord::StaleObjectError do |error|
        render_error(I18n.t(:"errors.stale_object"), status: :conflict)
      end

      rescue_from ActionController::ParameterMissing do |error|
        render_error(I18n.t(:"errors.parameter_missing", param: error.param), status: :bad_request)
      end
    end
  end
end
