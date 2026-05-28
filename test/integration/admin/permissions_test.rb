require "test_helper"

class AdminPermissionsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Core::Permission,
                policy_class: Admin::PermissionPolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/permissions",
                check_attributes: {
                  index: %w[id code resource action namespace],
                  show: %w[id code resource action namespace description active]
                },
                 create_params: -> {
                   { permission: {
                     code: "test_#{SecureRandom.hex(4)}",
                     resource: "test_resource",
                     action: SecureRandom.hex(4),
                     namespace: "core",
                     active: true
                   } }
                 },
                 update_params: ->(record) {
                   { permission: { description: "Updated permission #{SecureRandom.hex(4)}" } }
                 },
                 index: {
                   pagination: { per_page: 5 },
                   ordering: { order_by: "resource", direction: "asc" }
                 }
end
