module Core
  module PublicCommon
    extend ActiveSupport::Concern

    include Core::Pagination
    include Core::Filterable

    included do
      class_attribute :model_class, default: nil
      class_attribute :list_serializer, default: nil
      class_attribute :detail_serializer, default: nil
    end

    def index
      records = build_base_scope
      records = apply_catalog_filters(records)
      records = filter_records(records) if searchable?
      records = apply_ordering(records)

      total_count = records.count if paginated_request?
      records = paginated_request? ? apply_pagination(records) : records.limit(default_per_page)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil

      render_success(
        data: records,
        serializer_options: { serializer: self.class.list_serializer },
        pagination: pagination
      )
    end

    def show
      record = build_detail_scope.find(params[:id])
      render_success(
        data: record,
        serializer_options: { serializer: self.class.detail_serializer }
      )
    end

    private

    def build_base_scope
      base_scope
    end

    def base_scope
      self.class.model_class.all
    end

    def build_detail_scope
      detail_scope
    end

    def detail_scope
      self.class.model_class.all
    end

    def apply_catalog_filters(scope)
      scope
    end

    def searchable?
      false
    end

    def allowed_order_columns
      %w[id created_at]
    end
  end
end
