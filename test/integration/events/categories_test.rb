require "test_helper"

class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test skip_authorization: true,
                path: "/categories",
                check_attributes: {
                  index: %w[id name slug],
                  show: %w[id name description slug metadata active created_at updated_at]
                }
end
