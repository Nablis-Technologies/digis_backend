module Events
  class CategoriesController < ::Public::ApplicationController
    def index
      categories = Events::Category.active
      total_count = categories.count if paginated_request?
      categories = paginated_request? ? apply_pagination(categories) : categories.limit(25)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: categories, serializer_options: { serializer: Events::Public::CategoryListSerializer }, pagination: pagination)
    end

    def show
      category = Events::Category.find(params[:id])
      render_success(data: category, serializer_options: { serializer: Events::Public::CategoryDetailSerializer })
    end
  end
end
