# frozen_string_literal: true

require "test_helper"

module Messaging
  class RetentionScopeResolverTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    test "returns no scopes for an empty notification page" do
      assert_equal({}, Messaging::RetentionScopeResolver.call(notification_ids: []))
    end

    test "resolves event and registration scopes without duplicates" do
      create_messaging_policy
      setup_package_workflow(admissions_per_unit: 1)
      event_notification = create_messaging_notification(
        user: @owner, type: "schedule_changed", dedupe_key: SecureRandom.uuid
      )
      registration_notification = Messaging::Notification.create!(
        user: @owner,
        notification_type: "waitlist_offer_created",
        category: "transactional",
        source: @registration,
        data: {
          "registration_id" => @registration.id,
          "event_id" => @event.id,
          "offer_expires_at" => 1.hour.from_now.iso8601
        },
        dedupe_key: SecureRandom.uuid,
        retention_policy: Core::DataRetentionPolicy.active.find_by!(category: "messaging_notification"),
        retain_until: 1.day.from_now,
        available_at: Time.current
      )

      scopes = Messaging::RetentionScopeResolver.call(
        notification_ids: [ event_notification.id, registration_notification.id ]
      )

      assert_equal [ @owner.id ], scopes.fetch(event_notification.id).fetch(:user_ids)
      assert_equal [ @event.id ], scopes.fetch(event_notification.id).fetch(:event_ids)
      assert_equal [ @registration.id ], scopes.fetch(registration_notification.id).fetch(:registration_ids)
      assert_equal [ @event.id ], scopes.fetch(registration_notification.id).fetch(:event_ids)
    end
  end
end
