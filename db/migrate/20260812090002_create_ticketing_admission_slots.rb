# frozen_string_literal: true

class CreateTicketingAdmissionSlots < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_admission_slots, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.integer :position, limit: 2, null: false
      t.uuid :assigned_user_id
      t.string :assignment_status, null: false, default: "unassigned"
      t.timestamptz :claimed_at

      t.timestamps
    end

    add_check_constraint :ticketing_admission_slots,
      "position > 0",
      name: "ticketing_admission_slots_position_check"
    add_check_constraint :ticketing_admission_slots,
      "assignment_status IN ('unassigned','pending_claim','claimed')",
      name: "ticketing_admission_slots_status_check"
    add_check_constraint :ticketing_admission_slots,
      "(assignment_status = 'claimed' AND claimed_at IS NOT NULL) OR " \
        "(assignment_status <> 'claimed' AND claimed_at IS NULL)",
      name: "ticketing_admission_slots_claimed_at_check"

    add_index :ticketing_admission_slots, %i[ticket_id position], unique: true
    add_index :ticketing_admission_slots, %i[assigned_user_id assignment_status]

    add_foreign_key :ticketing_admission_slots, :ticketing_tickets, column: :ticket_id
    add_foreign_key :ticketing_admission_slots, :core_users, column: :assigned_user_id
  end
end
