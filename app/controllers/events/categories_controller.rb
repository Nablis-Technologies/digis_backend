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

    def allowed_order_columns
      %w[id name slug active created_at updated_at]
    end

    def serializer_profile
      {
        index: {
          fields: %i[id name slug]
        },
        show: {
          fields: %i[id name description slug metadata active created_at updated_at]
        },
        create: {
          fields: %i[id name slug]
        },
        update: {
          fields: %i[id name slug]
        }
      }
    end
  end
end
