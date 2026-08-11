# frozen_string_literal: true

class CreateTicketingRegistrationForms < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registration_forms, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :ticket_type_id
      t.string :name, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :ticketing_registration_forms,
      "event_id, lower(name)",
      unique: true,
      where: "ticket_type_id IS NULL",
      name: "idx_registration_forms_event_name"
    add_index :ticketing_registration_forms,
      "ticket_type_id, lower(name)",
      unique: true,
      where: "ticket_type_id IS NOT NULL",
      name: "idx_registration_forms_product_name"
    add_index :ticketing_registration_forms, %i[event_id active]

    add_foreign_key :ticketing_registration_forms, :events_events, column: :event_id
    add_foreign_key :ticketing_registration_forms, :ticketing_ticket_types, column: :ticket_type_id
  end
end
