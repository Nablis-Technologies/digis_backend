# frozen_string_literal: true

require "digest"
require "test_helper"

module Ticketing
  module Registrations
    class ConfirmPaidTest < ActiveSupport::TestCase
      include Finance::LedgerTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @buyer = core_users(:attendee)
        @manager = core_users(:super_admin)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Paid confirmation #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 100, active_from: Time.current },
          inventory_configuration: { mode: "unlimited" }
        ).value
        @product = Catalog::Products::Activate.call(product:, actor: @manager).value
        @registration = Registration.create!(
          event: @event,
          ticket_type: @product.ticket_type,
          user: @buyer,
          created_by: @buyer,
          source: "self_service",
          identity_digest: Digest::SHA256.hexdigest("paid-confirmation"),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: Time.current
        )
        @order = Orders::Order.create!(
          event: @event,
          buyer_user: @buyer,
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
          idempotency_key_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
          creation_request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid)
        )
        @item = Orders::OrderItem.create!(
          order: @order,
          event_product: @product,
          registration: @registration,
          name_snapshot: @product.name,
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
        @order.update!(status: "pending_payment")
        @payment = Orders::Payment.create!(
          order: @order,
          attempt_number: 1,
          provider: "chapa",
          payment_method: "telebirr",
          status: "processing",
          amount_minor: 100,
          currency: "ETB",
          commercial_signature: @order.commercial_signature,
          buyer_fee_minor: 0,
          organizer_fee_minor: 0,
          idempotency_key: "paid-confirm-payment",
          settlement_grace_minutes: 5,
          settlement_grace_expires_at: @order.expires_at + 5.minutes
        )
      end

      teardown do
        Core::AuditLog.where(auditable_type: "Ticketing::Registration", auditable_id: @registration&.id).delete_all
        cleanup_payment_ledger_entries(payment_ids: @payment&.id)
        Orders::Payment.where(id: @payment&.id).delete_all
        @order&.update_columns(status: "draft", paid_at: nil)
        Orders::OrderItem.where(id: @item&.id).delete_all
        Orders::Order.where(id: @order&.id).delete_all
        Registration.where(id: @registration&.id).delete_all
        Catalog::ProductAccess.where(event_product_id: @product&.id).delete_all
        Ticketing::TicketType.where(event_product_id: @product&.id).delete_all
        Catalog::ProductPrice.where(event_product_id: @product&.id).delete_all
        Catalog::EventProduct.where(id: @product&.id).delete_all
      end

      test "confirms a paid registration and audits an idempotent replay" do
        result = ConfirmPaid.call(registration: @registration, payment: @payment)

        assert_predicate result, :success?, result.error&.message
        assert_equal "confirmed", @registration.reload.status
        assert_not_nil @registration.confirmed_at

        replay = ConfirmPaid.call(registration: @registration, payment: @payment)

        assert_predicate replay, :success?, replay.error&.message
        assert_equal 1, Core::AuditLog.where(
          auditable_type: "Ticketing::Registration",
          auditable_id: @registration.id,
          action: "ticketing.registration.paid_confirmed"
        ).count
      end

      test "accepted payment confirms the linked registration before fulfillment" do
        result = Orders::AcceptPayment.call(payment: @payment)

        assert_predicate result, :success?, result.error&.message
        assert_equal "confirmed", @registration.reload.status
        assert_equal "fulfilled", @order.reload.status
      end
    end
  end
end
