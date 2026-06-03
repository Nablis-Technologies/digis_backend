module Events
  class CategoriesController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Events::Category
    self.list_serializer = Events::Public::CategoryListSerializer
    self.detail_serializer = Events::Public::CategoryDetailSerializer

    private

    def base_scope
      Events::Category.active
    end

    def allowed_order_columns
      %w[id name created_at]
    end
  end
end
