# frozen_string_literal: true

module Messaging
  # Reads and updates one user's category/channel preferences. Updates require
  # the shared idempotency header because a changed retry must fail closed.
  class NotificationPreferencesController < Messaging::ApplicationController
    before_action :ensure_idempotency_key_present, only: :update

    def show
      @clazz = Messaging::NotificationPreference
      authorize @clazz.new(user: current_user), :show?
      stored = policy_scope(@clazz).where(user_id: current_user.id).includes(:user)
      preferences = Messaging::NotificationPreference.effective_for(current_user, stored:)
      render_success(
        :"messaging.preferences.success.show",
        data: preferences,
        serializer_options: { serializer: Messaging::NotificationPreferenceSerializer }
      )
    end

    def update
      @clazz = Messaging::NotificationPreference
      authorize @clazz.new(user: current_user), :update?
      result = Messaging::UpdatePreferences.call(
        user: current_user,
        preferences: model_params.fetch(:preferences, []),
        idempotency_key:
      )
      return render_error(result.error.message, status: result.error.status_code, code: result.error.code) if result.failure?

      render_success(
        :"messaging.preferences.success.update",
        data: result.value,
        serializer_options: { serializer: Messaging::NotificationPreferenceSerializer }
      )
    end

    private

    def model_params
      params.permit(preferences: %i[category channel enabled]).to_h.deep_symbolize_keys
    end

    def eager_load_config
      { show: [ :user ], update: [ :user ], default: [] }
    end

    def allowed_order_columns
      %w[id category channel enabled created_at updated_at]
    end

    def serializer_profile
      fields = %i[id category channel enabled created_at updated_at]
      { show: { fields:, include: [] }, update: { fields:, include: [] } }
    end
  end
end
