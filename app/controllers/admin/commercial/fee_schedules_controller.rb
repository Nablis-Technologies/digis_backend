# frozen_string_literal: true

module Admin
  module Commercial
    # Platform-admin CRUD for stable schedule identities. Financial behavior is
    # authored on draft versions and never changed through this controller.
    class FeeSchedulesController < ApplicationController
      include Core::Common
      include Core::CommandResponse

      self.model_class = ::Commercial::FeeSchedule
      self.default_serializer = ::Commercial::FeeScheduleSerializer

      before_action :ensure_idempotency_key_present, only: %i[create update]

      def create
        schedule = @clazz.new(created_by: current_user)
        authorize schedule
        result = ::Commercial::Admin::PersistRecord.call(
          record: schedule, actor: current_user, attributes: schedule_params,
          idempotency_key:, action: "create"
        )
        render_service_result(result, success_status: :created)
      end

      def update
        set_object
        authorize @obj
        result = ::Commercial::Admin::PersistRecord.call(
          record: @obj, actor: current_user, attributes: schedule_params,
          idempotency_key:, action: "update"
        )
        render_service_result(result)
      end

      private

      def schedule_params
        params.require(:fee_schedule).permit(:name, :code, :schedule_type)
      end

      def model_params = schedule_params

      def serializer_profile
        { index: { include: [ :fee_schedule_versions ] }, show: { include: [ :fee_schedule_versions ] },
          create: { include: [ :fee_schedule_versions ] }, update: { include: [ :fee_schedule_versions ] } }
      end

      def eager_load_config
        {
          default: [
            {
              fee_schedule_versions: [
                { fee_components: %i[fee_amounts fee_tiers] },
                :assignments,
                :simulations
              ]
            }
          ]
        }
      end

      def allowed_order_columns
        %w[id name code schedule_type created_at updated_at]
      end
    end
  end
end
