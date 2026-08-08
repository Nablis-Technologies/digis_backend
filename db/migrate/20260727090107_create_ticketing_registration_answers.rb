# frozen_string_literal: true

class CreateTicketingRegistrationAnswers < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registration_answers, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_form_submission_id, null: false
      t.uuid :registration_question_id, null: false
      t.string :question_key_snapshot, null: false
      t.string :question_type_snapshot, null: false
      t.string :response_scope_snapshot, null: false
      t.string :question_label_snapshot, null: false
      t.integer :package_unit_number
      t.integer :admission_position, limit: 2
      t.uuid :admission_slot_id
      t.text :answer_ciphertext
      t.uuid :retention_policy_id, null: false
      t.timestamptz :retain_until
      t.timestamptz :answered_at, null: false
      t.timestamptz :erased_at
      t.string :erasure_reason

      t.timestamps
    end

    add_check_constraint :ticketing_registration_answers,
      "question_type_snapshot IN ('short_text','long_text','single_choice','multiple_choice','checkbox','date')",
      name: "ticketing_registration_answers_question_type_check"
    add_check_constraint :ticketing_registration_answers,
      "response_scope_snapshot IN ('registration','admission_slot')",
      name: "ticketing_registration_answers_response_scope_check"
    add_check_constraint :ticketing_registration_answers,
      "(response_scope_snapshot = 'registration' AND package_unit_number IS NULL " \
        "AND admission_position IS NULL AND admission_slot_id IS NULL) OR " \
        "(response_scope_snapshot = 'admission_slot' AND package_unit_number > 0 " \
        "AND admission_position > 0)",
      name: "ticketing_registration_answers_scope_coordinates_check"
    add_check_constraint :ticketing_registration_answers,
      "(erased_at IS NULL AND erasure_reason IS NULL AND answer_ciphertext IS NOT NULL) OR " \
        "(erased_at IS NOT NULL AND erasure_reason IS NOT NULL AND answer_ciphertext IS NULL)",
      name: "ticketing_registration_answers_erasure_check"
    add_check_constraint :ticketing_registration_answers,
      "erasure_reason IS NULL OR erasure_reason IN " \
        "('legal_request','policy_expiry','privacy_request','security_incident')",
      name: "ticketing_registration_answers_erasure_reason_check"

    add_index :ticketing_registration_answers,
      %i[registration_form_submission_id registration_question_id],
      unique: true,
      where: "response_scope_snapshot = 'registration'",
      name: "idx_registration_answers_registration_scope"
    add_index :ticketing_registration_answers,
      %i[registration_form_submission_id registration_question_id package_unit_number admission_position],
      unique: true,
      where: "response_scope_snapshot = 'admission_slot'",
      name: "idx_registration_answers_admission_scope"
    add_index :ticketing_registration_answers, :admission_slot_id
    add_index :ticketing_registration_answers, %i[retention_policy_id retain_until]

    add_foreign_key :ticketing_registration_answers,
                    :ticketing_registration_form_submissions,
                    column: :registration_form_submission_id
    add_foreign_key :ticketing_registration_answers,
                    :ticketing_registration_questions,
                    column: :registration_question_id
    add_foreign_key :ticketing_registration_answers,
                    :core_data_retention_policies,
                    column: :retention_policy_id
  end
end
