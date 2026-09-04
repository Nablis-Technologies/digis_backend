# frozen_string_literal: true

class CreateMessagingCreditAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_credit_accounts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.string :channel, null: false

      t.timestamps
    end

    add_check_constraint :messaging_credit_accounts,
      "channel IN ('sms','email')",
      name: "messaging_credit_accounts_channel_check"

    add_index :messaging_credit_accounts, %i[organization_id channel],
      unique: true,
      name: "idx_messaging_credit_accounts_organization_channel"

    add_foreign_key :messaging_credit_accounts, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
  end
end
