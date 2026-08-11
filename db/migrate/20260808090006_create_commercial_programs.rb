class CreateCommercialPrograms < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_programs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :fee_schedule_id, null: false
      t.string :program_type, null: false
      t.string :enrollment_mode, null: false, default: "automatic"
      t.timestamptz :starts_at
      t.timestamptz :ends_at
      t.integer :per_organization_use_limit
      t.boolean :active, null: false, default: false
      t.timestamps
    end

    add_index :commercial_programs, :fee_schedule_id, unique: true,
              name: "idx_commercial_programs_unique_schedule"
    add_index :commercial_programs, %i[active starts_at ends_at]
    add_index :commercial_programs, %i[program_type enrollment_mode]

    add_check_constraint :commercial_programs,
      "program_type IN ('first_monetized_event','charity','partnership','volume')",
      name: "commercial_programs_program_type_check"
    add_check_constraint :commercial_programs,
      "enrollment_mode IN ('automatic','manual')",
      name: "commercial_programs_enrollment_mode_check"
    add_check_constraint :commercial_programs,
      "per_organization_use_limit IS NULL OR per_organization_use_limit > 0",
      name: "commercial_programs_use_limit_check"
    add_check_constraint :commercial_programs,
      "ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at",
      name: "commercial_programs_effective_interval_check"

    add_foreign_key :commercial_programs, :commercial_fee_schedules,
                    column: :fee_schedule_id, on_delete: :restrict
  end
end
