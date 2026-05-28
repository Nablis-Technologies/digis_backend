require "test_helper"

class AdminRolesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Core::Role,
                policy_class: Admin::RolePolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/roles",
                check_attributes: {
                  index: %w[id code name active],
                  show: %w[id code name description active]
                },
                 create_params: -> {
                   { role: {
                     code: "TEST_ROLE_#{SecureRandom.hex(4)}",
                     name: "Test Role #{SecureRandom.hex(4)}",
                     active: true
                   } }
                 },
                 update_params: ->(record) {
                   { role: { description: "Updated role #{SecureRandom.hex(4)}" } }
                 },
                 index: {
                   pagination: { per_page: 2 },
                   ordering: { order_by: "code", direction: "asc" }
                 }
end
