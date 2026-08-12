# frozen_string_literal: true

module Admin
  module Commercial
    # Admin authoring surface for reusable commercial programs.
    class ProgramsController < ApplicationController
      include Core::Common
      include Core::CommandResponse

      self.model_class = ::Commercial::Program
      self.default_serializer = ::Commercial::ProgramSerializer

      before_action :ensure_idempotency_key_present, only: %i[create update]

      def create
        program = @clazz.new
        authorize program
        schedule = ::Commercial::FeeSchedule.find(program_params[:fee_schedule_id])
        program.fee_schedule = schedule
        result = ::Commercial::Admin::PersistRecord.call(
          record: program, actor: current_user, attributes: program_params.except(:fee_schedule_id),
          idempotency_key:, action: "create"
        )
        render_service_result(result, success_status: :created)
      end

      def update
        set_object
        authorize @obj
        result = ::Commercial::Admin::PersistRecord.call(
          record: @obj, actor: current_user, attributes: program_params.except(:fee_schedule_id),
          idempotency_key:, action: "update"
        )
        render_service_result(result)
      end

      private

      def program_params
        params.require(:program).permit(
          :fee_schedule_id, :program_type, :enrollment_mode, :starts_at, :ends_at,
          :per_organization_use_limit, :active
        )
      end

      def model_params = program_params
    end
  end
end
