# frozen_string_literal: true

class CreateFinanceProviderReservePolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :finance_provider_reserve_policies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :provider, null: false
      t.string :currency, limit: 3, null: false
      t.bigint :target_minor, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :finance_provider_reserve_policies, %i[provider currency], unique: true,
              name: "idx_finance_reserve_policies_on_provider_and_currency"
    add_check_constraint :finance_provider_reserve_policies,
      "currency ~ '^[A-Z]{3}$'",
      name: "finance_reserve_policies_currency_check"
    add_check_constraint :finance_provider_reserve_policies,
      "target_minor >= 0",
      name: "finance_reserve_policies_nonnegative_target_check"
    add_check_constraint :finance_provider_reserve_policies,
      "lock_version >= 0",
      name: "finance_reserve_policies_lock_version_check"
  end
end
