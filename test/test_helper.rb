ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :minitest
    with.library :rails
  end
end

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    set_fixture_class(
      core_users: Core::User,
      core_roles: Core::Role,
      core_permissions: Core::Permission,
      core_role_permissions: Core::RolePermission,
      core_user_roles: Core::UserRole,
      core_refresh_tokens: Core::RefreshToken,
      core_audit_logs: Core::AuditLog,
      core_reviews: Core::Review,
      events_categories: Events::Category
    )

    # Add more helper methods to be used by all tests here...
  end
end
