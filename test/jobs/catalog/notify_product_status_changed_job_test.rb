# frozen_string_literal: true

require "test_helper"

module Catalog
  class NotifyProductStatusChangedJobTest < ActiveJob::TestCase
    setup do
      @product = Catalog::Products::CreateDraft.call(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        product_attributes: { name: "Notification ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
    end

    test "passes product status changes to the injected sender" do
      notified = nil
      previous_sender = Rails.application.config.x.catalog_notification_sender
      Rails.application.config.x.catalog_notification_sender = lambda do |product:, event_type:|
        notified = [ product.id, event_type ]
      end

      Catalog::NotifyProductStatusChangedJob.perform_now(@product.id, "catalog.product.activated")

      assert_equal [ @product.id, "catalog.product.activated" ], notified
    ensure
      Rails.application.config.x.catalog_notification_sender = previous_sender
    end

    test "catalog outbox handlers enqueue notifications with event data" do
      event = Core::Outbox::Publish.call(
        topic: "catalog",
        event_type: "catalog.product.activated",
        aggregate: @product,
        payload: { product_id: @product.id, event_id: @product.event_id },
        idempotency_key: "catalog-notification-test-#{@product.id}"
      ).value

      assert_enqueued_with(
        job: Catalog::NotifyProductStatusChangedJob,
        args: [ @product.id, "catalog.product.activated" ]
      ) do
        Rails.application.config.x.outbox_handlers.fetch(event.event_type).call(event)
      end
    end
  end
end
