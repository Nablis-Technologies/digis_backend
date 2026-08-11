# frozen_string_literal: true

require "test_helper"

module Orders
  class OrderTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
    end

    test "reconciles the buyer total from immutable cached components" do
      order = Orders::Order.new(order_attributes)

      assert_predicate order, :valid?

      order.total_minor += 1

      assert_not order.valid?
      assert_includes order.errors.attribute_names, :total_minor
    end

    test "rejects negative cached amounts while allowing signed manual adjustments" do
      %i[subtotal_minor discount_minor subsidy_minor fee_minor tax_minor total_minor settlement_total_minor].each do |attribute|
        order = Orders::Order.new(order_attributes.merge(attribute => -1))

        assert_not order.valid?, "#{attribute} should reject negative values"
      end

      order = Orders::Order.new(order_attributes.merge(adjustment_minor: -250, total_minor: 8_750))

      assert_predicate order, :valid?
    end

    test "enforces status and sales-channel allowlists and closure metadata" do
      order = Orders::Order.new(order_attributes.merge(status: "unknown"))

      assert_not order.valid?
      assert_includes order.errors.attribute_names, :status

      order.status = "cancelled"
      assert_not order.valid?
      assert_includes order.errors.attribute_names, :closed_reason

      order.closed_reason = "buyer_cancelled"

      assert_predicate order, :valid?
    end

    test "persists order creation idempotency identity and rejects duplicate keys" do
      first = Orders::Order.create!(order_attributes)
      duplicate = Orders::Order.new(
        order_attributes.merge(
          idempotency_key_digest: first.idempotency_key_digest,
          creation_request_digest: SecureRandom.hex(32)
        )
      )

      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "allows one active checkout per buyer and event" do
      Orders::Order.create!(order_attributes)
      duplicate = Orders::Order.new(
        order_attributes.merge(
          idempotency_key_digest: SecureRandom.hex(32),
          creation_request_digest: SecureRandom.hex(32)
        )
      )

      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "requires a replacement to target the same buyer and event from a closed state" do
      original = Orders::Order.create!(
        order_attributes.merge(status: "expired", closed_reason: "checkout_expired")
      )
      replacement = Orders::Order.new(
        order_attributes.merge(
          replaces_order: original,
          idempotency_key_digest: SecureRandom.hex(32),
          creation_request_digest: SecureRandom.hex(32)
        )
      )

      assert_predicate replacement, :valid?

      replacement.buyer_user = core_users(:support)
      assert_not replacement.valid?
      assert_includes replacement.errors.attribute_names, :replaces_order

      replacement.buyer_user = @buyer
      replacement.event = events_events(:draft_concert)
      assert_not replacement.valid?
      assert_includes replacement.errors.attribute_names, :replaces_order

      draft_original = Orders::Order.create!(
        order_attributes.merge(
          idempotency_key_digest: SecureRandom.hex(32),
          creation_request_digest: SecureRandom.hex(32)
        )
      )
      replacement.replaces_order = draft_original
      replacement.event = @event
      assert_not replacement.valid?
      assert_includes replacement.errors.attribute_names, :replaces_order
    end

    test "keeps order snapshots immutable after pending payment at the model and database layers" do
      order = Orders::Order.create!(order_attributes.merge(status: "pending_payment"))
      order.subtotal_minor = 9_999

      assert_not order.save
      assert_includes order.errors.attribute_names, :subtotal_minor

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Order.where(id: order.id).update_all(subtotal_minor: 9_999)
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Order.where(id: order.id).delete_all
      end
    end

    test "requires products to belong to the order event" do
      order = Orders::Order.create!(order_attributes)
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Merchandise #{SecureRandom.hex(4)}",
        type: "merchandise",
        status: "active"
      )
      other_product = Catalog::EventProduct.create!(
        event: events_events(:draft_concert),
        name: "Other merchandise #{SecureRandom.hex(4)}",
        type: "merchandise",
        status: "active"
      )

      valid_item = Orders::OrderItem.new(order:, event_product: product, **item_attributes)
      invalid_item = Orders::OrderItem.new(order:, event_product: other_product, **item_attributes)

      assert_predicate valid_item, :valid?
      assert_not invalid_item.valid?
      assert_includes invalid_item.errors.attribute_names, :event_product
    end

    test "stores one promotion redemption per order and keeps it event-scoped" do
      order = Orders::Order.create!(order_attributes)
      promotion = Catalog::Promotion.create!(
        event: @event,
        name: "Launch discount #{SecureRandom.hex(4)}",
        type: "fixed",
        fixed_amount_minor: 500,
        currency: "ETB",
        status: "active"
      )
      redemption = Orders::PromotionRedemption.new(
        order:,
        promotion:,
        user: @buyer,
        status: "reserved",
        discount_minor: 500,
        currency: "ETB",
        idempotency_key: "promotion-#{SecureRandom.hex(8)}",
        expires_at: order.expires_at
      )

      assert_predicate redemption, :valid?

      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) do
          Orders::PromotionRedemption.insert_all!([
            {
              id: SecureRandom.uuid,
              order_id: order.id,
              promotion_id: promotion.id,
              user_id: @buyer.id,
              status: "expired",
              discount_minor: 500,
              currency: "ETB",
              idempotency_key: "expired-#{SecureRandom.hex(8)}",
              expires_at: order.expires_at,
              created_at: Time.current,
              updated_at: Time.current
            }
          ])
        end
      end

      redemption.status = "expired"
      redemption.released_at = Time.current
      assert_predicate redemption, :valid?

      redemption.released_at = nil
      assert_not redemption.valid?
      assert_includes redemption.errors.attribute_names, :released_at

      redemption.user = core_users(:support)
      assert_not redemption.valid?
      assert_includes redemption.errors.attribute_names, :user
    end

    private

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        subtotal_minor: 10_000,
        discount_minor: 1_000,
        subsidy_minor: 500,
        fee_minor: 500,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 9_000,
        settlement_currency: "ETB",
        settlement_total_minor: 9_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def item_attributes
      {
        name_snapshot: "Merchandise",
        type_snapshot: "merchandise",
        quantity: 1,
        admissions_per_unit_snapshot: nil,
        base_currency: "ETB",
        base_unit_amount_minor: 10_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 10_000,
        discount_minor: 0,
        total_minor: 10_000,
        fulfillment_status: "pending"
      }
    end
  end
end
