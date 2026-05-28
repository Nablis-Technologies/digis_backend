module Admin
  class UsersController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Core::User
    self.resource_param = :id
    self.default_serializer = Admin::UserSerializer

    auditable_model Core::User
    auditable on: %i[create update destroy deactivate reactivate],
              action: { deactivate: "update", reactivate: "update" }

    before_action :set_user, only: %i[deactivate reactivate]

    def deactivate
      authorize @obj

      raise Core::AuthenticationError.new("Cannot deactivate yourself", code: "self_deactivation") if @obj == current_user

      ActiveRecord::Base.transaction do
        @obj.update!(deactivated_at: Time.current, deactivated_reason: params[:deactivated_reason])
        Core::AuthService.call(operation: :revoke_all_user_tokens, user: @obj)
        render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] })
      end
    end

    def reactivate
      authorize @obj

      ActiveRecord::Base.transaction do
        @obj.update!(deactivated_at: nil, deactivated_reason: nil)
        render_success(data: @obj, serializer_options: { serializer: Admin::UserSerializer, include: [ :roles ] })
      end
    end

    private

    def set_user
      @obj = Core::User.find(params[:id])
    end

    def model_params
      params.require(:user).permit(:email, :phone, :password, :verified_at)
    end

    def apply_index_scope(scope)
      case params[:status]
      when "all"  then scope
      when "deactivated" then scope.deactivated
      else scope.active
      end
    end

    def allowed_order_columns
      %w[id email phone verified_at deactivated_at created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id email phone verified_at deactivated_at deactivated_reason], include: %i[roles] },
        show: { fields: %i[id email phone verified_at deactivated_at deactivated_reason created_at updated_at], include: %i[roles] },
        create: { fields: %i[id email phone verified_at], include: %i[roles] },
        update: { fields: %i[id email phone verified_at], include: %i[roles] }
      }
    end
  end
end
