require "test_helper"

class AdminCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Events::Category,
                policy_class: Admin::CategoryPolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/categories",
                create_params: -> { { category: { name: "New Category #{SecureRandom.hex(4)}" } } },
                update_params: ->(record) { { category: { name: "Updated #{record.name}" } } },
                check_attributes: {
                  index: %w[id name slug description metadata active created_at updated_at],
                  show: %w[id name slug description metadata active created_at updated_at]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "name", direction: "asc" }
                }
end
