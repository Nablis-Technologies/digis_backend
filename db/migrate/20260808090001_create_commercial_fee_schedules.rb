# frozen_string_literal: true

class CreateCommercialFeeSchedules < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_fee_schedules, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.string :schedule_type, null: false
      t.uuid :created_by_id, null: false

      t.timestamps
    end

    add_index :commercial_fee_schedules, :code, unique: true
    add_index :commercial_fee_schedules, :schedule_type
    add_check_constraint :commercial_fee_schedules,
      "schedule_type IN ('platform_default','program','custom')",
      name: "commercial_fee_schedules_schedule_type_check"
    add_check_constraint :commercial_fee_schedules,
      "code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'",
      name: "commercial_fee_schedules_code_check"
    add_foreign_key :commercial_fee_schedules, :core_users,
                    column: :created_by_id, on_delete: :restrict
  end
end
