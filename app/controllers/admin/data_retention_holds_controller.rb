# frozen_string_literal: true

module Admin
  class DataRetentionHoldsController < Admin::ApplicationController
    include Core::Common
    include Core::CommandResponse

    self.model_class = Core::DataRetentionHold

    before_action :set_hold, only: :release
    before_action :ensure_idempotency_key_present, only: %i[create release]

    def create
      authorize @clazz.new, :create?
      result = Core::Retention::PlaceHold.call(
        actor: current_user,
        scope: hold_params.slice(:event_id, :registration_id, :user_id),
        category: hold_params[:category],
        reason_code: hold_params[:reason_code],
        starts_at: hold_params[:starts_at],
        expires_at: hold_params[:expires_at],
        idempotency_key:
      )
      @obj = result.value if result.success?
      render_service_result(result, success_status: :created)
    end

    def release
      authorize @obj, :release?
      result = Core::Retention::ReleaseHold.call(
        hold: @obj, actor: current_user, idempotency_key:
      )
      render_service_result(result)
    end

    private

    def set_hold
      @obj = Core::DataRetentionHold.find(params[:id])
    end

    def hold_params
      params.require(:data_retention_hold).permit(
        :event_id, :registration_id, :user_id, :category, :reason_code, :starts_at, :expires_at
      )
    end

    def serializer_profile
      fields = %i[
        id event_id registration_id user_id category reason_code placed_by_id starts_at expires_at
        released_by_id released_at created_at updated_at
      ]
      {
        index: { fields:, include: [] },
        show: { fields:, include: [] },
        create: { fields:, include: [] },
        release: { fields:, include: [] }
      }
    end

    def eager_load_config
      { default: [] }
    end
  end
end
