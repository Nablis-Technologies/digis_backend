# frozen_string_literal: true

class CreateMessagingCreditLedgerEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_credit_ledger_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :credit_account_id, null: false
      t.uuid :rate_version_id
      t.string :entry_type, null: false
      t.bigint :quantity, null: false
      t.bigint :available_delta, null: false
      t.string :reference_type
      t.uuid :reference_id
      t.string :idempotency_key_digest, limit: 64, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :messaging_credit_ledger_entries,
      "entry_type IN ('top_up','reserve','consume','release','refund','expire','adjustment')",
      name: "messaging_credit_ledger_entries_type_check"
    add_check_constraint :messaging_credit_ledger_entries,
      "quantity > 0",
      name: "messaging_credit_ledger_entries_quantity_check"
    add_check_constraint :messaging_credit_ledger_entries,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_credit_ledger_entries_idempotency_check"
    add_check_constraint :messaging_credit_ledger_entries,
      "jsonb_typeof(metadata) = 'object'",
      name: "messaging_credit_ledger_entries_metadata_check"

    add_index :messaging_credit_ledger_entries,
      %i[credit_account_id entry_type idempotency_key_digest],
      unique: true,
      name: "idx_messaging_credit_ledger_account_operation"
    add_index :messaging_credit_ledger_entries,
      %i[credit_account_id created_at id],
      name: "idx_messaging_credit_ledger_account_created"
    add_index :messaging_credit_ledger_entries, %i[reference_type reference_id],
      name: "idx_messaging_credit_ledger_reference"

    add_foreign_key :messaging_credit_ledger_entries, :messaging_credit_accounts,
      column: :credit_account_id, on_delete: :restrict
    add_foreign_key :messaging_credit_ledger_entries, :messaging_credit_rate_versions,
      column: :rate_version_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION messaging_credit_ledger_entry_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'messaging_credit_ledger_entry_immutable' USING ERRCODE = '40001';
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_messaging_credit_ledger_entry_immutable
            ON messaging_credit_ledger_entries;
          CREATE TRIGGER trg_messaging_credit_ledger_entry_immutable
            BEFORE UPDATE OR DELETE ON messaging_credit_ledger_entries
            FOR EACH ROW EXECUTE FUNCTION messaging_credit_ledger_entry_immutable();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS trg_messaging_credit_ledger_entry_immutable
            ON messaging_credit_ledger_entries;
          DROP FUNCTION IF EXISTS messaging_credit_ledger_entry_immutable();
        SQL
      end
    end
  end
end
