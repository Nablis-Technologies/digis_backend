ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    set_fixture_class(
      platform_users: Platform::User,
      platform_roles: Platform::Role,
      platform_permissions: Platform::Permission,
      platform_role_permissions: Platform::RolePermission,
      platform_user_roles: Platform::UserRole,
      platform_refresh_tokens: Platform::RefreshToken,
      platform_audit_logs: Platform::AuditLog,
      platform_reviews: Platform::Review
    )

    # Add more helper methods to be used by all tests here...
  end
end
