# frozen_string_literal: true

require "test_helper"

module Orders
  class ReleaseBuyerRegistrationTest < ActiveSupport::TestCase
    include Ticketing::ConsentTestHelpers

    setup do
      setup_consent_context
      @ticket_type.update!(audience: "access_code")
      raw_code = "BUYER-RELEASE-#{SecureRandom.hex(4)}"
      @access_code = Ticketing::AccessCode.create!(
        ticket_type: @ticket_type,
        code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: raw_code),
        max_uses: 3,
        used_count: @registration.package_quantity,
        max_quantity_per_use: @registration.package_quantity,
        active: true
      )
      @registration.update!(access_code: @access_code)
    end

    test "cancels a buyer registration and returns its proof exactly once" do
      subject = -> do
        ReleaseBuyerRegistration.call(
          registration_id: @registration.id,
          buyer: @actor,
          idempotency_key: "orders-registration-release-#{SecureRandom.hex(4)}"
        )
      end

      assert_audit_idempotent(
        subject,
        action: "ticketing.registration.pending_released",
        auditable_type: "Ticketing::Registration",
        auditable_id: @registration.id
      )

      assert_equal "cancelled", @registration.reload.status
      assert_equal 0, @access_code.reload.used_count
    end

    test "returns forbidden for another buyer without taking checkout row locks" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = ReleaseBuyerRegistration.call(
        registration_id: @registration.id,
        buyer: core_users(:support),
        idempotency_key: "orders-registration-release-wrong-buyer"
      )

      assert_predicate result, :failure?
      assert_equal "registration_not_owned", result.error.code
      assert_empty statements.select { |sql| sql.match?(/FOR UPDATE/i) }
      assert_equal "pending_payment", @registration.reload.status
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "does not release a checkout while its payment is in progress" do
      order = create_linked_order(status: "pending_payment")
      create_payment(order:, status: "processing")
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = ReleaseBuyerRegistration.call(
        registration_id: @registration.id,
        buyer: @actor,
        idempotency_key: "orders-registration-release-processing"
      )

      assert_predicate result, :failure?
      assert_equal "registration_payment_in_progress", result.error.code
      assert_equal "pending_payment", order.reload.status
      assert_equal "pending_payment", @registration.reload.status
      assert_equal 1, @access_code.reload.used_count
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      order_lock_index = statements.index { |sql| sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i) }
      payment_lock_index = statements.index { |sql| sql.match?(/FROM\s+"orders_payments".*FOR UPDATE/i) }
      registration_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"ticketing_registrations".*FOR UPDATE/i)
      end

      assert_not_nil advisory_index
      assert_not_nil order_lock_index
      assert_not_nil payment_lock_index
      assert_not_nil registration_lock_index
      assert_operator advisory_index, :<, order_lock_index
      assert_operator order_lock_index, :<, payment_lock_index
      assert_operator payment_lock_index, :<, registration_lock_index
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "does not reacquire a linked order row while closing the checkout" do
      order = create_linked_order(status: "pending_payment")
      create_payment(order:, status: "failed")
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = ReleaseBuyerRegistration.call(
        registration_id: @registration.id,
        buyer: @actor,
        idempotency_key: "orders-registration-release-single-lock"
      )

      assert_predicate result, :success?, result.error&.message
      order_lock_count = statements.count do |sql|
        sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i)
      end
      payment_lock_count = statements.count do |sql|
        sql.match?(/FROM\s+"orders_payments".*FOR UPDATE/i)
      end

      assert_equal 1, order_lock_count
      assert_equal 1, payment_lock_count
      assert_equal "expired", order.reload.status
      assert_equal "cancelled", @registration.reload.status
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "rolls checkout and registration changes back when proof audit fails" do
      order = create_linked_order(status: "pending_payment")
      audit_error = Core::BusinessError.new("audit unavailable", code: "audit_unavailable", status: :conflict)
      audit_result = Core::BaseService::Result.failure(audit_error)

      result = with_audit_record_failure(audit_result) do
        ReleaseBuyerRegistration.call(
          registration_id: @registration.id,
          buyer: @actor,
          idempotency_key: "orders-registration-release-audit-failure"
        )
      end

      assert_predicate result, :failure?
      assert_equal "pending_payment", order.reload.status
      assert_equal "pending_payment", @registration.reload.status
      assert_equal 1, @access_code.reload.used_count
    end

    test "replays a cancelled registration before blocking terminal payment evidence" do
      order = create_linked_order(status: "expired")
      payment = create_payment(order:, status: "unknown")
      @registration.update!(status: "cancelled", cancelled_at: Time.current)

      result = ReleaseBuyerRegistration.call(
        registration_id: @registration.id,
        buyer: @actor,
        idempotency_key: "orders-registration-release-terminal-replay"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", order.reload.status
      assert_equal "unknown", payment.reload.status
      assert_equal 1, @access_code.reload.used_count
    end

    test "rejects a linked paid order without changing registration or proof" do
      order = create_linked_order(status: "paid")

      result = ReleaseBuyerRegistration.call(
        registration_id: @registration.id,
        buyer: @actor,
        idempotency_key: "orders-registration-release-paid"
      )

      assert_predicate result, :failure?
      assert_equal "registration_not_releasable", result.error.code
      assert_equal "paid", order.reload.status
      assert_equal "pending_payment", @registration.reload.status
      assert_equal 1, @access_code.reload.used_count
    end

    private

    def create_linked_order(status:)
      order = Orders::Order.create!(
        event: @event,
        buyer_user: @actor,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 100,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 100,
        settlement_currency: "ETB",
        settlement_total_minor: 100,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 1.hour.from_now,
        expires_at: 1.hour.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      Orders::OrderItem.create!(
        order:,
        event_product: @ticket_type.event_product,
        registration: @registration,
        name_snapshot: @ticket_type.event_product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 100,
        charge_currency: "ETB",
        charge_unit_amount_minor: 100,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 100,
        fulfillment_status: "pending"
      )
      update_attributes = { status: }
      update_attributes[:closed_reason] = "test_expired" if status == "expired"
      update_attributes[:paid_at] = Time.current if status == "paid"
      order.update!(update_attributes)
      order
    end

    def create_payment(order:, status:)
      Orders::Payment.create!(
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status:,
        amount_minor: 100,
        currency: "ETB",
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        provider_reference: "release-#{SecureRandom.hex(4)}",
        idempotency_key: "release-payment-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 3,
        settlement_grace_expires_at: order.expires_at + 3.minutes
      )
    end

    def with_audit_record_failure(result)
      writer = Core::Audit::Record.singleton_class
      writer.define_method(:call) { |*_arguments, **_keywords| result }
      yield
    ensure
      writer.remove_method(:call)
    end
  end
end
