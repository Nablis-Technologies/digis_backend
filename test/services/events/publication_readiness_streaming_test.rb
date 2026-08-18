# frozen_string_literal: true

require "test_helper"

module Events
  class PublicationReadinessStreamingTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @event.organization.reviews.find_or_create_by!(context: "verification", status: "approved")
      Events::ReplaceCategories.call(
        event: @event,
        category_ids: [ events_categories(:music).id ],
        actor: core_users(:super_admin)
      )
      make_publishable(@event, actor: core_users(:super_admin))
      @date = @event.event_dates.last
      @stream = Events::EventStream.create!(
        event_date: @date,
        provider: "youtube",
        provider_playback_id: "publication-#{SecureRandom.hex(4)}",
        access_protection: "public",
        status: "scheduled",
        live_from: @date.starts_at,
        live_until: @date.ends_at,
        replay_enabled: false,
        max_concurrent_devices: 1
      )
    end

    test "rejects a signed product promise from YouTube" do
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Signed promise #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      product.product_accesses.create!(event_date: @date, type: "stream", required_access_protection: "signed")

      result = Events::PublicationReadiness.call(event: @event)

      assert_predicate result, :failure?
      assert_equal "streaming_protection_unsupported", result.error.code
    end
  end
end
