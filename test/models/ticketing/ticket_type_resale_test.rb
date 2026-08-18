# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketTypeResaleTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Resale policy ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      @ticket_type = @product.ticket_type
    end

    test "defaults resale to disabled with one completed resale" do
      assert_not @ticket_type.resale_enabled
      assert_nil @ticket_type.resale_price_cap_type
      assert_equal 1, @ticket_type.max_completed_resales
      assert_equal 32_767, TicketType::MAX_COMPLETED_RESALES
    end

    test "requires a cap shape when resale is enabled" do
      @ticket_type.resale_enabled = true

      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_price_cap_type],
        I18n.t("ticketing.ticket_type.errors.resale_price_cap_type_required")
    end

    test "rejects retained cap fields while resale is disabled" do
      @ticket_type.assign_attributes(
        resale_enabled: false,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 5_000,
        resale_fixed_cap_currency: "ETB"
      )

      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_price_cap_type],
        I18n.t("ticketing.ticket_type.errors.resale_cap_must_be_blank_when_disabled")
    end

    test "requires a positive fixed cap and forbids a percentage cap" do
      @ticket_type.assign_attributes(
        resale_enabled: true,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 0,
        resale_fixed_cap_currency: "ETB",
        resale_percentage_cap_bps: 100
      )

      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_fixed_cap_minor],
        I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_minor_positive")
      assert_includes @ticket_type.errors[:resale_percentage_cap_bps],
        I18n.t("ticketing.ticket_type.errors.resale_percentage_cap_must_blank")
    end

    test "requires a fixed cap to use the event settlement currency" do
      @ticket_type.assign_attributes(
        resale_enabled: true,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 5_000,
        resale_fixed_cap_currency: "USD"
      )

      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_fixed_cap_currency],
        I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_currency_mismatch")
    end

    test "requires a positive percentage cap within the complete basis" do
      @ticket_type.assign_attributes(
        resale_enabled: true,
        resale_price_cap_type: "percentage",
        resale_percentage_cap_bps: 10_001
      )

      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_percentage_cap_bps],
        I18n.t("ticketing.ticket_type.errors.resale_percentage_cap_range")
    end

    test "rejects a completed resale limit above the platform hard maximum" do
      @ticket_type.max_completed_resales = TicketType::MAX_COMPLETED_RESALES + 1

      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:max_completed_resales],
        I18n.t("ticketing.ticket_type.errors.max_completed_resales_too_large")
    end

    test "database rejects a disabled policy retaining cap data" do
      assert_raises(ActiveRecord::StatementInvalid) do
        TicketType.transaction(requires_new: true) do
          @ticket_type.update_columns(
            resale_enabled: false,
            resale_price_cap_type: "fixed",
            resale_fixed_cap_minor: 5_000,
            resale_fixed_cap_currency: "ETB"
          )
        end
      end
    end

    test "database rejects a completed resale limit above the platform maximum" do
      assert_raises(ActiveRecord::StatementInvalid) do
        TicketType.transaction(requires_new: true) do
          sql = ActiveRecord::Base.sanitize_sql_array([
            "UPDATE ticketing_ticket_types SET max_completed_resales = ? WHERE id = ?",
            TicketType::MAX_COMPLETED_RESALES + 1,
            @ticket_type.id
          ])
          ActiveRecord::Base.connection.execute(sql)
        end
      end
    end
  end
end
