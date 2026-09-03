# frozen_string_literal: true

require "test_helper"

module Messaging
  class FanoutNotificationJobTest < ActiveJob::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    test "fan-out includes admins, affected holders, and affected registrations once" do
      setup_package_workflow(admissions_per_unit: 1)
      event = @event
      date = @product.product_accesses.first.event_date
      owner = core_users(:core_admin)
      holder = @owner
      registration_user = core_users(:super_admin)
      unrelated = Core::User.create!(email: "unrelated-#{SecureRandom.hex(4)}@example.test")
      Events::EventOrganization.create!(
        event:, organization: organizations_organizations(:three), type: "promoter",
        role: "collaborator", status: "active"
      )
      Ticketing::Registration.create!(
        event:, ticket_type: @product.ticket_type, user: registration_user, created_by: registration_user,
        source: "self_service", identity_digest: SecureRandom.hex(32), package_quantity: 1,
        admissions_per_unit_snapshot: 1, party_size: 1, status: "confirmed", submitted_at: Time.current,
        confirmed_at: Time.current
      )
      outbox = Core::Outbox::Publish.call(
        topic: "events", event_type: "events.schedule_changed", aggregate: event,
        payload: { event_id: event.id, version: 2, event_date_ids: [ date.id ] },
        idempotency_key: "fanout-schedule-#{SecureRandom.uuid}"
      ).value

      captured = []
      original = Messaging::PublishNotification.method(:call)
      Messaging::PublishNotification.define_singleton_method(:call) do |**attributes|
        captured << attributes.fetch(:recipient).id
        Core::BaseService::Result.success(:published)
      end

      begin
        Messaging::FanoutNotificationJob.perform_now(outbox.id)
      ensure
        Messaging::PublishNotification.define_singleton_method(:call, original)
      end

      assert_equal [ owner.id, holder.id, registration_user.id, core_users(:support).id ].sort, captured.uniq.sort
      refute_includes captured, unrelated.id
      assert_equal captured.length, captured.uniq.length
    end
  end
end
