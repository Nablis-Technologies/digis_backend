module Core
  module CrudTestHelpers
    private

    def assert_index(resource_path, headers: admin_headers)
      get resource_path, headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      assert payload["success"]
      assert payload["data"].present?
      payload["data"]
    end

    def assert_show(resource_path, record, headers: admin_headers, check_attributes: %w[id])
      get "#{resource_path}/#{record.id}", headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      assert payload["success"]
      check_attributes.each { |attr| assert payload.dig("data", attr).present?, "Expected data.#{attr} to be present" }
      payload["data"]
    end

    def assert_create(resource_path, params, headers: admin_headers, check_attributes: {})
      post resource_path, params: params, headers: headers, as: :json
      assert_response :created
      payload = JSON.parse(response.body)
      assert payload["success"]
      check_attributes.each { |key, value| assert_equal value, payload.dig("data", key.to_s) }
      payload["data"]
    end

    def assert_create_forbidden(resource_path, params, headers: user_headers)
      post resource_path, params: params, headers: headers, as: :json
      assert_response :forbidden
    end

    def assert_update(resource_path, record, params, headers: admin_headers, check_attributes: {})
      patch "#{resource_path}/#{record.id}", params: params, headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      assert payload["success"]
      check_attributes.each { |key, value| assert_equal value, payload.dig("data", key.to_s) }
      payload["data"]
    end

    def assert_update_forbidden(resource_path, record, params, headers: user_headers)
      patch "#{resource_path}/#{record.id}", params: params, headers: headers, as: :json
      assert_response :forbidden
    end

    def assert_destroy(resource_path, record, headers: admin_headers)
      delete "#{resource_path}/#{record.id}", headers: headers, as: :json
      assert_response :success
      payload = JSON.parse(response.body)
      assert payload["success"]
    end

    def assert_destroy_forbidden(resource_path, record, headers: user_headers)
      delete "#{resource_path}/#{record.id}", headers: headers, as: :json
      assert_response :forbidden
    end

    def assert_resource_deleted(model_class, record)
      assert_nil model_class.find_by(id: record.id)
    end

    def assert_resource_not_deleted(model_class, record)
      assert model_class.exists?(record.id)
    end
  end
end
