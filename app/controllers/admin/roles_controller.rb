module Admin
  class RolesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Core::Role
    self.default_serializer = Admin::RoleSerializer

    auditable_model Core::Role
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:role).permit(:code, :name, :description, :active, permission_ids: [])
    end

    def allowed_order_columns
      %w[id code name active created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id code name description active], include: %i[permissions] },
        show: { fields: %i[id code name description active created_at updated_at], include: %i[permissions] },
        create: { fields: %i[id code name active], include: %i[permissions] },
        update: { fields: %i[id code name active], include: %i[permissions] }
      }
    end
  end
end
