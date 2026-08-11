# frozen_string_literal: true

require "test_helper"

module Orders
  class OrderAdjustmentTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Adjustment product #{SecureRandom.hex(4)}",
        type: "merchandise",
        status: "active"
      )
      @order = Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_000,
        settlement_currency: "ETB",
        settlement_total_minor: 10_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      @item = Orders::OrderItem.create!(
        order: @order,
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: @product.type,
        quantity: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 10_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 10_000,
        discount_minor: 0,
        total_minor: 10_000,
        fulfillment_status: "pending"
      )
    end

    test "disables STI and accepts the business type discriminator" do
      assert_predicate Orders::OrderAdjustment.inheritance_column, :blank?
      adjustment = Orders::OrderAdjustment.new(type: "service_fee")

      assert_equal "service_fee", adjustment.type
    end

    test "allowlists adjustment types, payer fields, refund policies, calculations, bases, and funders" do
      adjustment = Orders::OrderAdjustment.new(adjustment_attributes)

      assert_predicate adjustment, :valid?

      adjustment.type = "unknown"
      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :type

      adjustment.type = "service_fee"
      adjustment.refund_policy = "unknown"
      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :refund_policy

      adjustment.refund_policy = "nonrefundable"
      adjustment.calculation_type = "unknown"
      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :calculation_type

      adjustment.calculation_type = "percentage"
      adjustment.basis_type = "unknown"
      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :basis_type

      adjustment.basis_type = "eligible_order_subtotal"
      adjustment.funded_by = "unknown"
      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :funded_by
    end

    test "enforces adjustment signs and commercial calculation shape" do
      discount = Orders::OrderAdjustment.new(
        adjustment_attributes.merge(
          type: "discount",
          amount_minor: -500,
          calculation_type: nil,
          basis_type: nil,
          rate_bps: nil,
          funded_by: nil,
          source_type: "Catalog::Promotion"
        )
      )
      fee = Orders::OrderAdjustment.new(adjustment_attributes)
      subsidy = Orders::OrderAdjustment.new(
        adjustment_attributes.merge(
          type: "subsidy",
          amount_minor: -250,
          funded_by: "platform",
          source_type: "Commercial::FeeComponent"
        )
      )

      assert_predicate discount, :valid?
      assert_predicate fee, :valid?
      assert_predicate subsidy, :valid?

      platform_fee = Orders::OrderAdjustment.new(adjustment_attributes.merge(funded_by: "platform"))
      assert_not platform_fee.valid?
      assert_includes platform_fee.errors.attribute_names, :funded_by

      fee.amount_minor = -1
      assert_not fee.valid?

      subsidy.amount_minor = 1
      assert_not subsidy.valid?

      fee.amount_minor = 100
      fee.basis_type = nil
      assert_not fee.valid?
      assert_includes fee.errors.attribute_names, :basis_type

      fixed = Orders::OrderAdjustment.new(
        adjustment_attributes.merge(
          calculation_type: "fixed",
          basis_type: nil,
          basis_minor: 1,
          rate_bps: nil,
          fixed_amount_minor: 100
        )
      )
      assert_not fixed.valid?
      assert_includes fixed.errors.attribute_names, :basis_minor
    end

    test "requires paired source evidence and rejects unknown resolution evidence keys" do
      adjustment = Orders::OrderAdjustment.new(adjustment_attributes.merge(source_id: nil))

      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :source_id

      adjustment.source_id = SecureRandom.uuid
      adjustment.resolution_evidence = { "secret" => "must not be persisted" }

      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :resolution_evidence
    end

    test "requires the adjustment currency to match its order" do
      adjustment = Orders::OrderAdjustment.new(adjustment_attributes.merge(currency: "USD"))

      assert_not adjustment.valid?
      assert_includes adjustment.errors.attribute_names, :currency
    end

    test "uses a composite foreign key to keep item-scoped adjustments on their order" do
      other_order = Orders::Order.create!(
        @order.attributes.except("id", "created_at", "updated_at", "lock_version").merge(
          status: "expired",
          closed_reason: "test_expired",
          idempotency_key_digest: SecureRandom.hex(32),
          creation_request_digest: SecureRandom.hex(32)
        )
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::OrderAdjustment.insert_all!([
          adjustment_attributes.except(:order, :order_item).merge(
            id: SecureRandom.uuid,
            order_id: other_order.id,
            order_item_id: @item.id,
            created_at: Time.current,
            updated_at: Time.current
          )
        ])
      end
    end

    test "keeps adjustments immutable after the order enters pending payment" do
      adjustment = Orders::OrderAdjustment.create!(adjustment_attributes)
      @order.update!(status: "pending_payment")
      adjustment.amount_minor = 200

      assert_not adjustment.save
      assert_includes adjustment.errors.attribute_names, :amount_minor

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::OrderAdjustment.where(id: adjustment.id).update_all(amount_minor: 200)
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::OrderAdjustment.where(id: adjustment.id).delete_all
      end
    end

    private

    def adjustment_attributes
      {
        order: @order,
        order_item: @item,
        type: "service_fee",
        label: "Service fee",
        charged_to: "buyer",
        amount_minor: 100,
        currency: "ETB",
        refund_policy: "nonrefundable",
        calculation_type: "percentage",
        basis_type: "eligible_order_subtotal",
        basis_minor: 10_000,
        rate_bps: 100,
        fixed_amount_minor: nil,
        minimum_minor: nil,
        maximum_minor: nil,
        funded_by: "buyer",
        source_type: "Commercial::FeeComponent",
        source_id: SecureRandom.uuid,
        resolution_evidence: {
          "scope" => { "product_type" => "merchandise" },
          "tier" => { "position" => 1 },
          "window" => { "type" => "checkout" },
          "rounding" => { "mode" => "half_up" },
          "explanation" => { "source" => "platform_default" }
        }
      }
    end
  end
end
