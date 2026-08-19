# frozen_string_literal: true

require "test_helper"

module Orders
  class PaymentTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = Orders::Order.create!(order_attributes)
    end

    test "allows only the first three sequential attempts" do
      assert_predicate Orders::Payment.new(payment_attributes(attempt_number: 1)), :valid?
      assert_predicate Orders::Payment.new(payment_attributes(attempt_number: 3)), :valid?

      [ 0, 4 ].each do |attempt_number|
        payment = Orders::Payment.new(payment_attributes(attempt_number:))

        assert_not payment.valid?
        assert_includes payment.errors.attribute_names, :attempt_number
      end
    end

    test "requires payment amount, currency, and commercial signature to match the order attempt" do
      amount_mismatch = Orders::Payment.new(payment_attributes(amount_minor: 999))
      currency_mismatch = Orders::Payment.new(payment_attributes(currency: "USD"))
      missing_signature = Orders::Payment.new(payment_attributes(commercial_signature: "invalid"))

      [ amount_mismatch, currency_mismatch, missing_signature ].each do |payment|
        assert_not payment.valid?
      end
      assert_includes amount_mismatch.errors.attribute_names, :amount_minor
      assert_includes currency_mismatch.errors.attribute_names, :currency
      assert_includes missing_signature.errors.attribute_names, :commercial_signature
    end

    test "allows a provider attempt before a hosted checkout URL exists" do
      payment = Orders::Payment.new(payment_attributes)

      assert_predicate payment, :valid?, payment.errors.full_messages
      assert_nil payment.checkout_url
    end

    test "allows compatible cross-provider retries with the same commercial signature" do
      first = Orders::Payment.create!(payment_attributes(provider: "chapa", payment_method: "telebirr"))
      retry_payment = Orders::Payment.new(
        payment_attributes(
          attempt_number: 2,
          provider: "stripe",
          payment_method: "card",
          idempotency_key: "retry-#{SecureRandom.hex(6)}"
        )
      )

      assert_predicate retry_payment, :valid?
      assert_equal first.commercial_signature, retry_payment.commercial_signature
    end

    test "rejects a changed commercial signature for another attempt" do
      Orders::Payment.create!(payment_attributes)
      changed = Orders::Payment.new(
        payment_attributes(
          attempt_number: 2,
          commercial_signature: "b" * 64,
          idempotency_key: "changed-#{SecureRandom.hex(6)}"
        )
      )

      assert_not changed.valid?
      assert_includes changed.errors.attribute_names, :commercial_signature
    end

    test "stores the fee triple and clamps grace to the documented range" do
      payment = Orders::Payment.create!(
        payment_attributes(
          buyer_fee_minor: 100,
          organizer_fee_minor: 250,
          provider_fee_minor: 75,
          provider_fee_currency: "ETB",
          settlement_grace_minutes: 15
        )
      )

      assert_equal [ 100, 250, 75 ], payment.reload.values_at(
        "buyer_fee_minor", "organizer_fee_minor", "provider_fee_minor"
      )

      [ 2, 16 ].each do |minutes|
        candidate = Orders::Payment.new(payment_attributes(settlement_grace_minutes: minutes))

        assert_not candidate.valid?
        assert_includes candidate.errors.attribute_names, :settlement_grace_minutes
      end
    end

    test "allows only one current attempt and one accepted payment per order" do
      Orders::Payment.create!(payment_attributes(status: "processing"))

      assert_raises(ActiveRecord::RecordNotUnique) do
        Orders::Payment.create!(
          payment_attributes(
            attempt_number: 2,
            idempotency_key: "current-#{SecureRandom.hex(6)}"
          )
        )
      end

      first = Orders::Payment.create!(
        payment_attributes(
          attempt_number: 2,
          status: "succeeded",
          accepted_at: Time.current,
          idempotency_key: "accepted-#{SecureRandom.hex(6)}"
        )
      )
      second = Orders::Payment.new(
        payment_attributes(
          attempt_number: 3,
          status: "succeeded",
          accepted_at: Time.current,
          idempotency_key: "accepted-#{SecureRandom.hex(6)}"
        )
      )

      assert_equal "succeeded", first.status
      assert_raises(ActiveRecord::RecordNotUnique) { second.save!(validate: false) }
    end

    test "uniquely identifies each provider idempotency key and reference" do
      first = Orders::Payment.create!(payment_attributes(provider_reference: "provider-ref"))

      assert_raises(ActiveRecord::RecordNotUnique) do
        Orders::Payment.create!(
          payment_attributes(
            attempt_number: 2,
            status: "failed",
            idempotency_key: first.idempotency_key
          )
        )
      end

      assert_raises(ActiveRecord::RecordNotUnique) do
        Orders::Payment.create!(
          payment_attributes(
            attempt_number: 2,
            status: "failed",
            idempotency_key: "different-#{SecureRandom.hex(6)}",
            provider_reference: "provider-ref"
          )
        )
      end
    end

    test "database rejects amount, currency, and commercial signature drift" do
      base = payment_attributes.except(:order).merge(
        order_id: @order.id,
        id: SecureRandom.uuid,
        created_at: Time.current,
        updated_at: Time.current
      )

      assert_database_rejection(base.merge(amount_minor: 999))
      assert_database_rejection(base.merge(id: SecureRandom.uuid, currency: "USD"))

      Orders::Payment.insert_all!([ base ])

      assert_database_rejection(base.merge(id: SecureRandom.uuid, commercial_signature: "b" * 64))
    end

    test "deduplicates provider events by provider and provider event id" do
      payment = Orders::Payment.create!(payment_attributes)
      event_attributes = {
        payment:,
        provider: "chapa",
        provider_event_id: "evt-#{SecureRandom.hex(6)}",
        event_type: "payment.succeeded",
        status: "received",
        payload: { "status" => "success" },
        payload_digest: "a" * 64,
        received_at: Time.current
      }
      Orders::PaymentEvent.create!(event_attributes)

      assert_raises(ActiveRecord::RecordNotUnique) do
        Orders::PaymentEvent.create!(event_attributes)
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

    def payment_attributes(overrides = {})
      {
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "created",
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: "a" * 64,
        buyer_fee_minor: 500,
        organizer_fee_minor: 0,
        provider_fee_minor: nil,
        provider_fee_currency: nil,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: nil,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: 15.minutes.from_now,
        accepted_at: nil,
        superseded_at: nil
      }.merge(overrides)
    end

    def assert_database_rejection(attributes)
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) do
          Orders::Payment.insert_all!([ attributes ])
        end
      end
    end
  end
end
