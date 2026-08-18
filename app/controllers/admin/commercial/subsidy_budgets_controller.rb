# frozen_string_literal: true

module Admin
  module Commercial
    # Inspects and authors hard subsidy capacity. Reservation counters are
    # owned by checkout commands and are never writable through this API.
    class SubsidyBudgetsController < ApplicationController
      include Core::Common
      include Core::CommandResponse

      self.model_class = ::Commercial::SubsidyBudget
      self.default_serializer = ::Commercial::SubsidyBudgetSerializer

      before_action :ensure_idempotency_key_present, only: %i[create update]

      def create
        budget = @clazz.new
        authorize budget
        result = ::Commercial::Admin::PersistRecord.call(
          record: budget, actor: current_user, attributes: budget_params,
          idempotency_key:, action: "create", permission: "commercial.budget_view"
        )
        render_service_result(result, success_status: :created)
      end

      def update
        set_object
        authorize @obj
        result = ::Commercial::Admin::PersistRecord.call(
          record: @obj, actor: current_user, attributes: budget_params,
          idempotency_key:, action: "update", permission: "commercial.budget_view"
        )
        render_service_result(result)
      end

      private

      def budget_params
        params.require(:subsidy_budget).permit(
          :assignment_id, :program_id, :fee_component_id, :currency, :limit_minor
        )
      end

      def model_params = budget_params
    end
  end
end
