module Core
  module PaginationTestHelpers
    private

    def assert_pagination_works(resource_path, headers: admin_headers, per_page: 2)
      get "#{resource_path}?page=1&per_page=#{per_page}", headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      assert payload["pagination"].present?, "Expected pagination metadata"
      assert_equal per_page, payload["pagination"]["per_page"]
      assert_equal 1, payload["pagination"]["current_page"]
      %w[total_count total_pages links].each do |key|
        assert payload["pagination"][key].present?, "Expected pagination.#{key} to be present"
      end
      payload
    end

    def assert_filtering_works(resource_path, filter_params:, headers: admin_headers, check: ->(item, _param) { true })
      get "#{resource_path}?#{filter_params}", headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      assert payload["data"].present?
      payload["data"].each { |item| assert check.call(item, filter_params), "Filter failed for item: #{item}" }
      payload["data"]
    end

    def assert_ordering_works(resource_path, order_by:, direction: "desc", headers: admin_headers)
      get "#{resource_path}?order_by=#{order_by}&order_direction=#{direction}", headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      values = payload["data"].map { |item| item[order_by.to_s] }
      sorted = values.sort_by { |v| v.to_s.downcase }.reverse
      assert_equal sorted, values, "Expected #{order_by} to be ordered #{direction}"
      payload["data"]
    end
  end
end
