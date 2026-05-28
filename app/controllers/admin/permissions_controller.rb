module Admin
  class PermissionsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Core::Permission
    self.default_serializer = Admin::PermissionSerializer

    auditable_model Core::Permission
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:permission).permit(:code, :resource, :action, :namespace, :description, :active)
    end

    def allowed_order_columns
      %w[id code resource action namespace active created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: %i[id code resource action namespace description active] },
        show: { fields: %i[id code resource action namespace description active created_at updated_at] },
        create: { fields: %i[id code resource action namespace] },
        update: { fields: %i[id code resource action namespace] }
      }
    end
  end
end
