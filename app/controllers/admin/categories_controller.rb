module Admin
  class CategoriesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Category

    auditable on: %i[create update destroy]

    private

    def allowed_order_columns
      %w[id name created_at updated_at]
    end

    def model_params
      params.require(:category).permit(:name, :description, :slug, :active, metadata: {})
    end
  end
end
