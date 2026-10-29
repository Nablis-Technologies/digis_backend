# frozen_string_literal: true

require "test_helper"

module Links
  class BackfillCanonicalLinksJobTest < ActiveJob::TestCase
    setup do
      @event = events_events(:ready_listing)
      @organization = organizations_organizations(:two)
      @ticket = create_target_ticket
      configure_links(enabled: true)
    end

    teardown do
      Links::ShortLinkClick.delete_all
      Links::ShortLink.delete_all
      configure_links(enabled: false)
    end

    test "backfills events, tickets, and organizations repeatably" do
      Links::BackfillCanonicalLinksJob.perform_now

      canonical = Links::ShortLink.where(canonical: true)
      first_snapshot = canonical.order(:target_type, :target_id).pluck(:target_type, :target_id, :id, :slug)

      event_link = Links::ShortLink.find_by!(canonical: true, target_type: "event", target_id: @event.id)
      assert_equal @event.slug, event_link.slug
      ticket_link = Links::ShortLink.find_by!(canonical: true, target_type: "ticket", target_id: @ticket.id)
      assert_match(/\At-[a-z0-9]{6}\z/, ticket_link.slug)
      assert_includes first_snapshot.map(&:first), "ticket"
      assert_includes first_snapshot.map(&:first), "organization"

      Links::BackfillCanonicalLinksJob.perform_now

      assert_equal first_snapshot, canonical.reload.order(:target_type, :target_id).pluck(:target_type, :target_id, :id, :slug)
    end

    test "preserves an existing canonical link for a target" do
      preserved = Links::ShortLink.create!(
        slug: "preserved-event", target_type: "event", target_id: @event.id,
        canonical: true, click_count: 4
      )

      Links::BackfillCanonicalLinksJob.perform_now

      assert_equal preserved.id, Links::ShortLink.find_by!(canonical: true, target_type: "event", target_id: @event.id).id
      assert_equal "preserved-event", preserved.reload.slug
      assert_equal 4, preserved.click_count
    end

    test "retries a deterministic suffix when the target slug is already used" do
      Links::ShortLink.create!(
        slug: @event.slug, custom_url: "https://example.test/campaign", canonical: false
      )

      Links::BackfillCanonicalLinksJob.perform_now

      canonical = Links::ShortLink.find_by!(canonical: true, target_type: "event", target_id: @event.id)
      refute_equal @event.slug, canonical.slug
      assert_match(/\A#{Regexp.escape(@event.slug)}-[0-9a-f]{8}\z/, canonical.slug)
    end

    test "does nothing while branded links are disabled" do
      configure_links(enabled: false)

      assert_no_changes -> { Links::ShortLink.count } do
        Links::BackfillCanonicalLinksJob.perform_now
      end
    end

    private

    def configure_links(enabled:)
      Rails.application.config.x.short_links.enabled = enabled
    end

    def create_target_ticket
      product_id = SecureRandom.uuid
      order_id = SecureRandom.uuid
      item_id = SecureRandom.uuid
      ticket_id = SecureRandom.uuid
      now = Time.current

      Catalog::EventProduct.insert_all!([ {
        id: product_id, event_id: @event.id, name: "Backfill target ticket", type: "ticket",
        status: "active", inventory_mode: "unlimited", allow_custom_price: false,
        min_per_order: 1, schedule_change_refund_policy: "full_or_partial", sort_order: 0,
        metadata: {}, lock_version: 0, created_at: now, updated_at: now
      } ])
      Orders::Order.insert_all!([ {
        id: order_id, event_id: @event.id, buyer_user_id: core_users(:attendee).id,
        sales_channel: "online", status: "draft", charge_currency: "ETB",
        commercial_signature: "a" * 64, subtotal_minor: 1_000, discount_minor: 0,
        subsidy_minor: 0, fee_minor: 0, tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", expires_at: 1.hour.from_now,
        idempotency_key_digest: SecureRandom.hex(32), creation_request_digest: SecureRandom.hex(32),
        created_at: now, updated_at: now
      } ])
      Orders::OrderItem.insert_all!([ {
        id: item_id, order_id:, event_product_id: product_id, name_snapshot: "Backfill target ticket",
        type_snapshot: "ticket", quantity: 1, admissions_per_unit_snapshot: 1,
        base_currency: "ETB", base_unit_amount_minor: 1_000, charge_currency: "ETB",
        charge_unit_amount_minor: 1_000, exchange_rate: 1, discount_minor: 0, total_minor: 1_000,
        fulfillment_status: "fulfilled", created_at: now, updated_at: now
      } ])
      Ticketing::Ticket.insert_all!([ {
        id: ticket_id, event_id: @event.id, event_product_id: product_id, order_item_id: item_id,
        unit_number: 1, admissions_per_unit_snapshot: 1, owner_user_id: core_users(:attendee).id,
        current_acquisition_type: "primary_purchase", current_acquisition_order_item_id: item_id,
        current_acquisition_product_value_minor: 1_000, current_acquisition_currency: "ETB",
        completed_resale_count: 0, credential_mode: "group", credential_version: 1,
        status: "active", issued_at: now, lock_version: 0, created_at: now, updated_at: now
      } ])
      Ticketing::Ticket.find(ticket_id)
    end
  end
end
