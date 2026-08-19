# frozen_string_literal: true

require "test_helper"

module Links
  class RedirectsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @event = events_events(:ready_listing)
      @ticket = create_target_ticket
      configure_links(enabled: true)
      @link = create_link(slug: "controller-#{SecureRandom.hex(4)}", target_type: "event", target_id: @event.id)
    end

    teardown do
      Links::ShortLinkClick.where(short_link_id: @link.id).delete_all
      @link.destroy!
      configure_links(enabled: false)
    end

    test "redirects to the normal internal route and records analytics asynchronously" do
      assert_enqueued_with(job: Links::RecordClickJob, args: [ @link.id ]) do
        get "/#{@link.slug}", headers: { "HOST" => "links.test" }
      end

      assert_response :redirect
      assert_equal Rails.application.routes.url_helpers.event_path(@event.id), redirect_path
    end

    test "falls back to the normal route while links are disabled" do
      configure_links(enabled: false)

      get "/#{@link.slug}", headers: { "HOST" => "links.test" }

      assert_response :redirect
      assert_equal Rails.application.routes.url_helpers.event_path(@event.id), redirect_path
      assert_equal 0, @link.reload.click_count
    end

    test "keeps ticket targets as page routes rather than credentials" do
      ticket_link = create_link(
        slug: "ticket-#{SecureRandom.hex(4)}",
        target_type: "ticket",
        target_id: @ticket.id
      )

      get "/#{ticket_link.slug}", headers: { "HOST" => "links.test" }

      assert_response :redirect
      assert_equal "/tickets/#{@ticket.id}", redirect_path
    end

    test "returns gone for an expired link" do
      @link.update!(expires_at: 1.minute.ago)

      get "/#{@link.slug}", headers: { "HOST" => "links.test" }

      assert_response :gone
    end

    private

    def configure_links(enabled:)
      config = Rails.application.config.x.short_links
      config.enabled = enabled if config
      config.host = "links.test" if config
    end

    def create_link(slug:, target_type:, target_id:)
      Links::ShortLink.create!(
        slug:, target_type:, target_id:, creator_id: core_users(:super_admin).id,
        canonical: false, click_count: 0
      )
    end

    def redirect_path
      URI.parse(response.headers.fetch("Location")).request_uri
    end

    def create_target_ticket
      product_id = SecureRandom.uuid
      order_id = SecureRandom.uuid
      item_id = SecureRandom.uuid
      ticket_id = SecureRandom.uuid
      now = Time.current

      Catalog::EventProduct.insert_all!([ {
        id: product_id,
        event_id: @event.id,
        name: "Target ticket",
        type: "ticket",
        status: "active",
        inventory_mode: "unlimited",
        allow_custom_price: false,
        min_per_order: 1,
        schedule_change_refund_policy: "full_or_partial",
        sort_order: 0,
        metadata: {},
        lock_version: 0,
        created_at: now,
        updated_at: now
      } ])
      Orders::Order.insert_all!([ {
        id: order_id,
        event_id: @event.id,
        buyer_user_id: core_users(:attendee).id,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        subtotal_minor: 1_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 1_000,
        settlement_currency: "ETB",
        settlement_total_minor: 1_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        expires_at: 1.hour.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32),
        created_at: now,
        updated_at: now
      }.tap do |attributes|
        attributes[:commercial_signature] = "a" * 64 if Orders::Order.column_names.include?("commercial_signature")
      end ])
      Orders::OrderItem.insert_all!([ {
        id: item_id,
        order_id:,
        event_product_id: product_id,
        name_snapshot: "Target ticket",
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 1_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 1_000,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 1_000,
        fulfillment_status: "fulfilled",
        created_at: now,
        updated_at: now
      } ])
      Ticketing::Ticket.insert_all!([ {
        id: ticket_id,
        event_id: @event.id,
        event_product_id: product_id,
        order_item_id: item_id,
        unit_number: 1,
        admissions_per_unit_snapshot: 1,
        owner_user_id: core_users(:attendee).id,
        current_acquisition_type: "primary_purchase",
        current_acquisition_order_item_id: item_id,
        current_acquisition_product_value_minor: 1_000,
        current_acquisition_currency: "ETB",
        completed_resale_count: 0,
        credential_mode: "group",
        credential_version: 1,
        status: "active",
        issued_at: now,
        lock_version: 0,
        created_at: now,
        updated_at: now
      } ])
      Ticketing::Ticket.find(ticket_id)
    end
  end
end
