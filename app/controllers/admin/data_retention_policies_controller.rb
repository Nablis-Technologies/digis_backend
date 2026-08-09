# frozen_string_literal: true

module Admin
  class DataRetentionPoliciesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Core::DataRetentionPolicy

    auditable_model Core::DataRetentionPolicy
    auditable on: %i[create update]

    def create
      super
    rescue ActiveRecord::RecordNotUnique
      render_error(I18n.t(:"errors.not_unique"), status: :unprocessable_entity)
    end

    def update
      super
    rescue ActiveRecord::RecordNotUnique
      render_error(I18n.t(:"errors.not_unique"), status: :unprocessable_entity)
    end

    private

    def model_params
      attributes = params.require(:data_retention_policy).permit(
        :category, :jurisdiction_code, :version, :retention_days, :action, :status, :effective_at
      )
      attributes[:created_by_id] = current_user.id if action_name == "create"
      attributes
    end

    def eager_load_config
      { default: [ :created_by ] }
    end

    def allowed_order_columns
      %w[id category jurisdiction_code version retention_days action status effective_at created_at updated_at]
    end

    def serializer_profile
      fields = %i[id category jurisdiction_code version retention_days action status effective_at created_by_id created_at updated_at]
      {
        index: { fields:, include: [] },
        show: { fields:, include: [] },
        create: { fields:, include: [] },
        update: { fields:, include: [] }
      }
    end
  end
end
