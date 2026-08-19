if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start "rails" do
    add_filter "/bin/"
    add_filter "/db/"
    add_filter "/vendor/"
    add_filter "/lib/generators/"
  end
end

ENV["RAILS_ENV"] ||= "test"
# Load before Rails initializes test hooks because some tests use
# Prosopite.pause even when N+1 scanning is disabled.
require "prosopite"
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
    include DatabaseRaceHelper

    # Fork-based parallelism is fast, but on macOS forking crashes under the
    # Objective-C runtime (+[NSNumber initialize]...) unless the shell exports
    # OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES before running tests. Set it
    # once in your shell profile to get full parallel speed on macOS:
    #   export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
    if RUBY_PLATFORM.match?(/darwin/) && ENV["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] != "YES"
      parallelize(workers: 1)
    else
      parallelize(workers: ENV.fetch("PARALLEL_WORKERS", 6).to_i)
    end
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
      events_events: Events::Event,
      events_event_settings: Events::EventSetting,
      events_event_categories: Events::EventCategory,
      organizations_organizations: Organizations::Organization,
      organizations_memberships: Organizations::Membership,
    )

    if ENV["N_PLUS_ONE"] == "1"
      setup do
        Prosopite.scan
      end

      teardown do
        Prosopite.finish
      end
    end

    # Gives an event the minimum state required by Events::PublicationReadiness:
    # at least one scheduled date and a cover image with alt text.
    def make_publishable(event, actor: nil)
      actor ||= event.created_by || core_users(:super_admin)
      event.event_dates.create!(
        starts_at: 1.month.from_now.beginning_of_hour,
        ends_at: 1.month.from_now.beginning_of_hour + 2.hours,
        status: "scheduled"
      )
      cover = Events::EventMedia.create!(event: event, created_by: actor, type: "cover", position: 0) do |m|
        m.file.attach(io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
                      filename: "pixel.png", content_type: "image/png")
      end
      cover.file.blob.analyze
      cover.update!(alt_text: "Accessibility description for the event cover")
    end
  end
end
