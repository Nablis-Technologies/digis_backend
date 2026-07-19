require "simplecov"
SimpleCov.start "rails" do
  add_filter "/bin/"
  add_filter "/db/"
  add_filter "/vendor/"
  add_filter "/lib/generators/"
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
require "minitest/reporters"
require "mocha/minitest"

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :minitest
    with.library :rails
  end
end

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
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
      core_outbox_events: Core::OutboxEvent,
      events_categories: Events::Category,
      organizations_organizations: Organizations::Organization,
      organizations_memberships: Organizations::Membership,
    )

    setup do
      Prosopite.scan
    end

    teardown do
      Prosopite.finish
    end
  end
end
