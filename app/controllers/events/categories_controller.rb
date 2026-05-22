module Events
  class CategoriesController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Category

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:category).permit(:name, :description, :slug, :active, metadata: {})
    end

    def eager_loaded_associations
      []
    end

    def allowed_order_columns
      %w[id name slug active created_at updated_at]
    end

    def default_serializer_includes
      {
        index: [],
        show: [],
        create: [],
        update: []
      }
    end
  end
end
