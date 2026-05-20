module Core
  module Pagination
    extend ActiveSupport::Concern

    def default_per_page
      25
    end

    def max_per_page
      100
    end

    def page_no
      page = params[:page].to_i
      page.positive? ? page : 1
    end

    def per_page
      requested = params[:per_page].to_i
      return default_per_page if requested <= 0

      [requested, max_per_page].min
    end

    def paginated_request?
      params[:page].present?
    end

    def paginate_offset
      (page_no - 1) * per_page
    end

    def order_by
      allowed = respond_to?(:allowed_order_columns, true) ? allowed_order_columns : %w[id created_at updated_at]
      requested = params.fetch(:order_by, "id").to_s
      allowed.include?(requested) ? requested : "id"
    end

    def order_direction
      requested = params.fetch(:order_direction, "desc").to_s.downcase
      %w[asc desc].include?(requested) ? requested : "desc"
    end

    def apply_pagination(records)
      records.order(order_by => order_direction).limit(per_page).offset(paginate_offset)
    end

    def pagination_metadata(total_count)
      total_pages = (total_count.to_f / per_page).ceil
      {
        current_page: page_no,
        per_page: per_page,
        total_count: total_count,
        total_pages: total_pages,
        links: pagination_links(total_pages)
      }
    end

    def pagination_links(total_pages)
      return {} if total_pages <= 0

      base_path = request.path
      query_params = request.query_parameters.except("page")

      {
        first: build_page_url(base_path, query_params, 1),
        prev: page_no > 1 ? build_page_url(base_path, query_params, page_no - 1) : nil,
        next: page_no < total_pages ? build_page_url(base_path, query_params, page_no + 1) : nil,
        last: build_page_url(base_path, query_params, total_pages)
      }
    end

    private

    def build_page_url(base_path, query_params, page)
      all_params = query_params.merge(page: page, per_page: per_page)
      query = all_params.to_query
      url = "#{request.base_url}#{base_path}"
      query.present? ? "#{url}?#{query}" : url
    end
  end
end
