module Admin
  class UserRolesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Core::UserRole
    self.parent_class = Core::User
    self.parent_param = :user_id
    self.parent_association = :user_roles
    self.resource_param = :role_id

    auditable_model Core::UserRole
    auditable on: %i[create destroy]

    auditable_record_for :destroy, -> { @obj }

    private

    def after_create_hook(object)
      object.update!(assigned_by_id: current_user.id)
    end

    def model_params
      params.require(:user_role).permit(:role_id)
    end

    def eager_load_config
      { default: [ :role ] }
    end

    def allowed_order_columns
      %w[id created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id role_id], include: %i[role] },
        create: { fields: %i[id role_id], include: %i[role] }
      }
    end
  end
end
