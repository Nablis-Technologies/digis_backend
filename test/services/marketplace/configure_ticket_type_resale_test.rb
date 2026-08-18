# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ConfigureTicketTypeResaleTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Configurable resale ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      @ticket_type = @product.ticket_type
    end

    test "configures a fixed cap in the event settlement currency" do
      result = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: core_users(:super_admin),
        attributes: {
          resale_enabled: true,
          resale_price_cap_type: "fixed",
          resale_fixed_cap_minor: 7_500,
          resale_fixed_cap_currency: "etb",
          max_completed_resales: 2
        },
        idempotency_key: "configure-fixed-cap"
      )

      assert_predicate result, :success?
      assert_equal true, result.value.resale_enabled
      assert_equal "fixed", result.value.resale_price_cap_type
      assert_equal "ETB", result.value.resale_fixed_cap_currency
      assert_equal 2, result.value.max_completed_resales
    end

    test "clears cap fields when resale is disabled" do
      @ticket_type.update!(
        resale_enabled: true,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 7_500,
        resale_fixed_cap_currency: "ETB"
      )

      result = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: core_users(:super_admin),
        attributes: { resale_enabled: false },
        idempotency_key: "configure-disable"
      )

      assert_predicate result, :success?
      assert_not result.value.resale_enabled
      assert_nil result.value.resale_price_cap_type
      assert_nil result.value.resale_fixed_cap_minor
      assert_nil result.value.resale_fixed_cap_currency
      assert_nil result.value.resale_percentage_cap_bps
    end

    test "rejects a fixed cap in a different event currency without mutation" do
      result = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: core_users(:super_admin),
        attributes: {
          resale_enabled: true,
          resale_price_cap_type: "fixed",
          resale_fixed_cap_minor: 7_500,
          resale_fixed_cap_currency: "USD"
        },
        idempotency_key: "configure-invalid-currency"
      )

      assert_predicate result, :failure?
      assert_equal "resale_fixed_cap_currency_mismatch", result.error.code
      assert_not @ticket_type.reload.resale_enabled
    end

    test "replays the same key without duplicating the policy audit" do
      attributes = {
        resale_enabled: true,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 7_500,
        resale_fixed_cap_currency: "ETB",
        max_completed_resales: 2
      }
      subject = -> do
        ConfigureTicketTypeResale.call(
          ticket_type: @ticket_type,
          actor: core_users(:super_admin),
          attributes:,
          idempotency_key: "configure-replay"
        )
      end

      assert_audit_idempotent(
        subject,
        action: "marketplace.resale_policy.updated",
        auditable_type: "Ticketing::TicketType",
        auditable_id: @ticket_type.id
      )
    end

    test "rejects reusing a key for different policy attributes" do
      first = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: core_users(:super_admin),
        attributes: { resale_enabled: true, resale_price_cap_type: "fixed", resale_fixed_cap_minor: 7_500,
                       resale_fixed_cap_currency: "ETB", max_completed_resales: 2 },
        idempotency_key: "configure-conflict"
      )
      second = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: core_users(:super_admin),
        attributes: { resale_enabled: false },
        idempotency_key: "configure-conflict"
      )

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :failure?
      assert_equal "idempotency_conflict", second.error.code
    end
  end
end
