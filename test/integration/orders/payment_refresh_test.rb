# frozen_string_literal: true

require "digest"
require "json"
require "test_helper"

module Orders
  class PaymentRefreshTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = Orders::Order.create!(order_attributes)
      @payment = Orders::Payment.create!(payment_attributes)
      @provider = ::Payments::Providers::FakePaymentProvider.new(
        outcomes: { verify: [ ::Payments::Providers::Result.success(provider_reference: "provider-ref") ] }
      )
      ::Payments::Providers::Registry.register("chapa", @provider)
    end

    teardown do
      ::Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "requires an idempotency key" do
      post "/payments/#{@payment.id}/refresh", headers: user_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "returns the buyer-safe pending projection with no-store" do
      @payment.update!(status: "succeeded", succeeded_at: Time.current, accepted_at: Time.current)

      post "/payments/#{@payment.id}/refresh",
        headers: user_headers.merge("Idempotency-Key" => "refresh-terminal-api"), as: :json

      assert_response :success
      assert_equal "no-store", response.headers.fetch("Cache-Control")
      data = response.parsed_body.fetch("data")
      assert_equal "pending", data.fetch("state")
      assert_equal @payment.id, data.fetch("payment").fetch("id")
      assert_equal @order.id, data.fetch("order").fetch("id")
      assert_equal [], data.fetch("tickets")
      refute data.fetch("payment").key?("idempotency_key")
    end

    test "verifies and processes a pending payment from its stored reference" do
      post "/payments/#{@payment.id}/refresh",
        headers: user_headers.merge("Idempotency-Key" => "refresh-pending-api"), as: :json

      assert_response :success
      assert_equal "pending", response.parsed_body.dig("data", "state")
      assert_equal "fulfilled", @order.reload.status
      assert @payment.reload.accepted_at
      assert_equal [ { provider_reference: "provider-ref", idempotency_key: "provider-ref" } ],
                   @provider.requests_for("provider-ref")
    end

    test "does not reveal a payment belonging to another buyer" do
      post "/payments/#{@payment.id}/refresh",
        headers: admin_headers.merge("Idempotency-Key" => "refresh-other-buyer"), as: :json

      assert_response :not_found
    end

    test "returns ready with the owner-scoped wallet serializer when tickets exist" do
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Refresh ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1,
          transferable: true
        },
        price_attributes: { currency: "ETB", amount_minor: 10_500, active_from: Time.current },
        inventory_configuration: { mode: "unlimited" }
      ).value
      product.ticket_type.update!(
        resale_enabled: true,
        resale_price_cap_type: "percentage",
        resale_percentage_cap_bps: 7_500,
        resale_cutoff_seconds_before_start: 3_600,
        max_completed_resales: 4
      )
      date = @event.event_dates.create!(
        starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours, status: "scheduled"
      )
      product.product_accesses.create!(event_date: date, type: "venue", usage_limit: 1)
      product = Catalog::Products::Activate.call(product:, actor: core_users(:super_admin)).value
      @order.update_columns(status: "fulfilled", paid_at: Time.current)
      wallet_order = Orders::Order.create!(order_attributes.merge(
        status: "draft", idempotency_key_digest: SecureRandom.hex(32), creation_request_digest: SecureRandom.hex(32)
      ))
      item = wallet_order.order_items.create!(
        event_product: product, name_snapshot: product.name, type_snapshot: "ticket", quantity: 1,
        admissions_per_unit_snapshot: 1, base_currency: "ETB", base_unit_amount_minor: 10_500,
        charge_currency: "ETB", charge_unit_amount_minor: 10_500, exchange_rate: 1,
        discount_minor: 0, total_minor: 10_500, fulfillment_status: "fulfilled"
      )
      add_on = Catalog::EventProduct.create!(
        event: @event, name: "Refresh add-on", type: "merchandise", status: "active",
        inventory_mode: "unlimited", schedule_change_refund_policy: "full_or_partial"
      )
      add_on_item = wallet_order.order_items.create!(
        event_product: add_on, name_snapshot: add_on.name, type_snapshot: "merchandise",
        quantity: 1, base_currency: "ETB", base_unit_amount_minor: 750,
        charge_currency: "ETB", charge_unit_amount_minor: 750, exchange_rate: 1,
        discount_minor: 0, total_minor: 750, fulfillment_status: "fulfilled"
      )
      wallet_order.update!(subtotal_minor: 10_750, total_minor: 11_250, settlement_total_minor: 11_250)
      wallet_order.update_columns(status: "fulfilled", paid_at: Time.current)
      ticket = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1).value
      initiated_transfer = Ticketing::Transfers::Initiate.call(
        ticket:,
        actor: @buyer,
        phone: core_users(:core_admin).phone,
        idempotency_key: "refresh-wallet-transfer-#{SecureRandom.hex(4)}"
      )
      assert_predicate initiated_transfer, :success?, initiated_transfer.error&.message
      payment = Orders::Payment.create!(payment_attributes.merge(
        order: wallet_order, status: "succeeded", succeeded_at: Time.current, accepted_at: Time.current,
        idempotency_key: "wallet-refresh-#{SecureRandom.hex(4)}",
        provider_reference: "wallet-provider-#{SecureRandom.hex(4)}",
        amount_minor: wallet_order.total_minor,
        settlement_grace_expires_at: wallet_order.expires_at + 5.minutes
      ))

      post "/payments/#{payment.id}/refresh",
        headers: user_headers.merge("Idempotency-Key" => "refresh-wallet-api"), as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_equal "ready", data.fetch("state")
      wallet_ticket = data.fetch("tickets").find { |entry| entry.fetch("id") == ticket.id }
      assert wallet_ticket
      assert_equal 7_875, wallet_ticket.dig("ticket_type", "resale_price_cap_minor")
      pending_transfer = wallet_ticket.fetch("pending_transfer")
      assert_equal %w[expires_at id status], pending_transfer.keys.sort
      assert_equal initiated_transfer.value.transfer.id, pending_transfer.fetch("id")
      assert_equal "pending", pending_transfer.fetch("status")
      refute_includes response.body, initiated_transfer.value.token
      refute_includes response.body, initiated_transfer.value.transfer.token_digest
      refute_includes response.body, core_users(:core_admin).phone
      refute wallet_ticket.key?("owner_user_id")
      refute wallet_ticket.key?("ticket_view_token")
      refute wallet_ticket.key?("ticket_view_url")
      refute wallet_ticket.key?("short_url")
      assert wallet_ticket.key?("credentials")
      assert_equal [
        {
          "id" => add_on_item.id,
          "name" => "Refresh add-on",
          "type" => "merchandise",
          "quantity" => 1,
          "unit_amount_minor" => 750
        }
      ], wallet_ticket.fetch("add_ons")
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
        idempotency_key_digest: Digest::SHA256.hexdigest("refresh-order-#{SecureRandom.uuid}"),
        creation_request_digest: Digest::SHA256.hexdigest("refresh-order-request-#{SecureRandom.uuid}")
      }
    end

    def payment_attributes
      {
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "processing",
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 500,
        organizer_fee_minor: 0,
        idempotency_key: "tx-ref-#{SecureRandom.uuid}",
        provider_reference: "provider-ref",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end
  end
end
