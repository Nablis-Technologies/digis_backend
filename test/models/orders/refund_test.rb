# frozen_string_literal: true

require "test_helper"

module Orders
  class RefundTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @order = Orders::Order.create!(order_attributes)
      @payment = Orders::Payment.create!(payment_attributes)
    end

    test "models payment reversals as a non-STI full refund" do
      refund = Orders::Refund.new(refund_attributes)

      assert_predicate refund, :valid?, refund.errors.full_messages
      assert_equal "payment_reversal", refund.type
      assert_equal @payment.amount_minor, refund.amount_minor
    end

    test "rejects a payment reversal for an accepted payment or partial amount" do
      @payment.update_columns(accepted_at: Time.current)
      accepted_refund = Orders::Refund.new(refund_attributes)

      assert_not accepted_refund.valid?
      assert_includes accepted_refund.errors.attribute_names, :payment

      @payment.update_columns(accepted_at: nil)
      partial_refund = Orders::Refund.new(refund_attributes(amount_minor: 1))

      assert_not partial_refund.valid?
      assert_includes partial_refund.errors.attribute_names, :payment
    end

    test "database rejects reversal evidence that does not match the succeeded payment" do
      @payment.update_columns(status: "failed")

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Refund.insert_all!([ refund_attributes.except(:payment).merge(
          id: SecureRandom.uuid,
          payment_id: @payment.id,
          created_at: Time.current,
          updated_at: Time.current
        ) ])
      end
    end

    test "requires a reason when a refund is pending for provider funds" do
      refund = Orders::Refund.new(refund_attributes(status: "pending_funds"))

      assert_not refund.valid?
      assert_includes refund.errors.attribute_names, :pending_reason
    end

    test "database rejects a refund in another currency" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Refund.insert_all!([
          refund_attributes(currency: "USD").except(:payment).merge(
            id: SecureRandom.uuid,
            payment_id: @payment.id,
            created_at: Time.current,
            updated_at: Time.current
          )
        ])
      end
    end

    test "database rejects a refund with a nonpositive amount" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Refund.insert_all!([
          refund_attributes(amount_minor: 0).except(:payment).merge(
            id: SecureRandom.uuid,
            payment_id: @payment.id,
            created_at: Time.current,
            updated_at: Time.current
          )
        ])
      end
    end

    test "database rejects inconsistent provider fee evidence" do
      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Refund.insert_all!([
          refund_attributes(provider_fee_minor: 10).except(:payment).merge(
            id: SecureRandom.uuid,
            payment_id: @payment.id,
            created_at: Time.current,
            updated_at: Time.current
          )
        ])
      end
    end

    test "database rejects a cancellation belonging to another event" do
      cancellation = Events::EventCancellation.create!(
        event: events_events(:draft_concert),
        initiated_by: @buyer,
        status: "pending",
        idempotency_key: "cancellation-#{SecureRandom.uuid}",
        attendee_reason: "The event will not proceed.",
        initiated_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Orders::Refund.insert_all!([
          refund_attributes(event_cancellation_id: cancellation.id).except(:payment).merge(
            id: SecureRandom.uuid,
            payment_id: @payment.id,
            created_at: Time.current,
            updated_at: Time.current
          )
        ])
      end
    end

    private

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "pending_payment",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 500,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_500,
        settlement_currency: "ETB",
        settlement_total_minor: 10_500,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def payment_attributes
      {
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 500,
        organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: "provider-ref-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end

    def refund_attributes(overrides = {})
      {
        payment: @payment,
        type: "payment_reversal",
        idempotency_key: "refund-#{SecureRandom.hex(6)}",
        amount_minor: @payment.amount_minor,
        currency: @payment.currency,
        status: "created",
        reason_code: "late_payment"
      }.merge(overrides)
    end
  end
end
