# frozen_string_literal: true

class CreateCommercialSubsidyBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_subsidy_budgets, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :assignment_id
      t.uuid :program_id
      t.uuid :fee_component_id, null: false
      t.string :currency, null: false, limit: 3
      t.bigint :limit_minor, null: false
      t.bigint :reserved_minor, null: false, default: 0
      t.bigint :consumed_minor, null: false, default: 0
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :commercial_subsidy_budgets,
      %i[assignment_id fee_component_id currency],
      unique: true,
      where: "assignment_id IS NOT NULL",
      name: "idx_commercial_subsidy_budgets_assignment_component_currency"
    add_index :commercial_subsidy_budgets,
      %i[program_id fee_component_id currency],
      unique: true,
      where: "program_id IS NOT NULL",
      name: "idx_commercial_subsidy_budgets_program_component_currency"
    add_index :commercial_subsidy_budgets,
      %i[fee_component_id currency],
      name: "idx_commercial_subsidy_budgets_component_currency"

    add_check_constraint :commercial_subsidy_budgets,
      "(assignment_id IS NOT NULL AND program_id IS NULL) OR " \
        "(assignment_id IS NULL AND program_id IS NOT NULL)",
      name: "commercial_subsidy_budgets_owner_check"
    add_check_constraint :commercial_subsidy_budgets,
      "currency ~ '^[A-Z]{3}$'",
      name: "commercial_subsidy_budgets_currency_check"
    add_check_constraint :commercial_subsidy_budgets,
      "limit_minor > 0",
      name: "commercial_subsidy_budgets_limit_check"
    add_check_constraint :commercial_subsidy_budgets,
      "reserved_minor >= 0",
      name: "commercial_subsidy_budgets_reserved_check"
    add_check_constraint :commercial_subsidy_budgets,
      "consumed_minor >= 0",
      name: "commercial_subsidy_budgets_consumed_check"
    add_check_constraint :commercial_subsidy_budgets,
      "reserved_minor + consumed_minor <= limit_minor",
      name: "commercial_subsidy_budgets_counter_limit_check"
    add_check_constraint :commercial_subsidy_budgets,
      "lock_version >= 0",
      name: "commercial_subsidy_budgets_lock_version_check"

    add_foreign_key :commercial_subsidy_budgets,
      :commercial_assignments,
      column: :assignment_id,
      on_delete: :restrict
    add_foreign_key :commercial_subsidy_budgets,
      :commercial_programs,
      column: :program_id,
      on_delete: :restrict
    add_foreign_key :commercial_subsidy_budgets,
      :commercial_fee_components,
      column: :fee_component_id,
      on_delete: :restrict
  end
end
