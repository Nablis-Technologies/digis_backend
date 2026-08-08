# frozen_string_literal: true

class CreateTicketingRegistrationQuestions < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registration_questions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_form_version_id, null: false
      t.string :key, null: false
      t.string :type, null: false
      t.string :response_scope, null: false
      t.string :sensitivity, null: false
      t.string :label, null: false
      t.text :help_text
      t.boolean :required, null: false, default: false
      t.integer :position, null: false, default: 0
      t.jsonb :options, null: false, default: []
      t.jsonb :validation_rules, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :ticketing_registration_questions,
      "type IN ('short_text','long_text','single_choice','multiple_choice','checkbox','date')",
      name: "ticketing_registration_questions_type_check"
    add_check_constraint :ticketing_registration_questions,
      "response_scope IN ('registration','admission_slot')",
      name: "ticketing_registration_questions_response_scope_check"
    add_check_constraint :ticketing_registration_questions,
      "sensitivity IN ('standard','dietary','accessibility')",
      name: "ticketing_registration_questions_sensitivity_check"
    add_check_constraint :ticketing_registration_questions,
      "position >= 0",
      name: "ticketing_registration_questions_position_check"
    add_check_constraint :ticketing_registration_questions,
      "jsonb_typeof(options) = 'array' AND jsonb_typeof(validation_rules) = 'object'",
      name: "ticketing_registration_questions_json_shape_check"

    add_index :ticketing_registration_questions,
      %i[registration_form_version_id key],
      unique: true,
      name: "idx_registration_questions_version_key"
    add_index :ticketing_registration_questions,
      %i[registration_form_version_id position],
      unique: true,
      name: "idx_registration_questions_version_position"

    add_foreign_key :ticketing_registration_questions,
                    :ticketing_registration_form_versions,
                    column: :registration_form_version_id
  end
end
