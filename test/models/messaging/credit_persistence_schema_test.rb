# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class CreditPersistenceSchemaTest < ActiveSupport::TestCase
    TABLES = %w[
      messaging_credit_accounts
      messaging_credit_rate_versions
      messaging_credit_ledger_entries
      messaging_credit_reservations
      messaging_credit_top_ups
    ].freeze

    test "creates one table for each credit aggregate" do
      TABLES.each { |table| assert db_connection.table_exists?(table), "missing #{table}" }
    end

    test "credit accounts have organization and channel uniqueness" do
      assert_table_exists("messaging_credit_accounts")
      columns = db_connection.columns("messaging_credit_accounts").index_by(&:name)

      assert_equal :uuid, columns.fetch("organization_id").type
      assert_equal :string, columns.fetch("channel").type
      assert_unique_index("messaging_credit_accounts", %w[organization_id channel])
      assert_check_constraint("messaging_credit_accounts", "channel")
    end

    test "rate versions support organization-specific and global pricing" do
      assert_table_exists("messaging_credit_rate_versions")
      columns = db_connection.columns("messaging_credit_rate_versions").index_by(&:name)

      assert_equal :uuid, columns.fetch("organization_id").type
      assert columns.fetch("organization_id").null
      assert_equal :jsonb, columns.fetch("volume_tiers").type
      assert_equal :integer, columns.fetch("version").type
      assert_unique_index(
        "messaging_credit_rate_versions",
        %w[organization_id channel currency country_code version]
      )
      assert_check_constraint("messaging_credit_rate_versions", "channel")
    end

    test "ledger entries expose immutable evidence and idempotency" do
      assert_table_exists("messaging_credit_ledger_entries")
      columns = db_connection.columns("messaging_credit_ledger_entries").index_by(&:name)

      assert_equal :uuid, columns.fetch("credit_account_id").type
      assert_equal 8, columns.fetch("available_delta").limit
      assert_equal :string, columns.fetch("idempotency_key_digest").type
      assert_unique_index(
        "messaging_credit_ledger_entries",
        %w[credit_account_id entry_type idempotency_key_digest]
      )
      assert_check_constraint("messaging_credit_ledger_entries", "entry_type")
    end

    test "database trigger prevents editing or deleting ledger evidence" do
      account = Messaging::CreditAccount.create!(organization: organizations_organizations(:one), channel: "sms")
      entry = Messaging::CreditLedgerEntry.create!(
        credit_account: account, entry_type: "top_up", quantity: 1, available_delta: 1,
        idempotency_key_digest: Digest::SHA256.hexdigest("immutable-schema"), metadata: {}
      )

      assert_raises(ActiveRecord::StatementInvalid) { entry.update_columns(quantity: 2) }
      assert_raises(ActiveRecord::StatementInvalid) { entry.delete }
    end

    test "reservations use neutral source references instead of a campaigns foreign key" do
      assert_table_exists("messaging_credit_reservations")
      columns = db_connection.columns("messaging_credit_reservations").index_by(&:name)

      assert_equal :string, columns.fetch("source_type").type
      assert_equal :uuid, columns.fetch("source_id").type
      assert_not columns.key?("campaign_id")
      assert_unique_index(
        "messaging_credit_reservations",
        %w[source_type source_id channel]
      )
      assert_check_constraint("messaging_credit_reservations", "status")
    end

    test "top-ups link to an Orders billing purchase" do
      assert_table_exists("messaging_credit_top_ups")
      columns = db_connection.columns("messaging_credit_top_ups").index_by(&:name)

      assert_equal :uuid, columns.fetch("orders_billing_purchase_id").type
      assert_equal :string, columns.fetch("status").type
      assert_equal :string, columns.fetch("request_digest").type
      assert_unique_index("messaging_credit_top_ups", %w[organization_id idempotency_key_digest])
      assert_check_constraint("messaging_credit_top_ups", "status")
    end

    test "Orders provides a non-event billing purchase subject" do
      assert_table_exists("orders_billing_purchases")
      columns = db_connection.columns("orders_billing_purchases").index_by(&:name)

      assert_equal :uuid, columns.fetch("organization_id").type
      assert_equal 8, columns.fetch("amount_minor").limit
      assert_equal :string, columns.fetch("price_digest").type
      assert_check_constraint("orders_billing_purchases", "status")
    end

    test "Orders payments permit exactly one event or billing subject" do
      columns = db_connection.columns("orders_payments").index_by(&:name)

      assert columns.fetch("order_id").null
      assert columns.fetch("billing_purchase_id").null
      assert columns.fetch("commercial_signature").null
      assert_equal :string, columns.fetch("billing_purchase_price_digest").type
      assert_check_constraint("orders_payments", "billing_purchase_id")
      assert_check_constraint("orders_payments", "commercial_signature")
    end

    private

    def assert_unique_index(table, columns)
      indexes = db_connection.indexes(table)
      assert indexes.any? { |index| index.unique && index.columns == columns },
        "missing unique index #{table}(#{columns.join(', ')})"
    end

    def assert_table_exists(table)
      assert db_connection.table_exists?(table), "missing #{table}"
    end

    def assert_check_constraint(table, fragment)
      constraints = db_connection.check_constraints(table)
      assert constraints.any? { |constraint| constraint.expression.include?(fragment) },
        "missing check constraint containing #{fragment.inspect} on #{table}"
    end

    def db_connection
      ActiveRecord::Base.connection
    end
  end
end
