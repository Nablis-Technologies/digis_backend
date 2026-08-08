# frozen_string_literal: true

class CreateTicketingRegistrationAnswerRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registration_answer_revisions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_answer_id, null: false
      t.integer :revision_number, null: false
      t.text :answer_ciphertext
      t.uuid :revised_by_id, null: false
      t.string :source, null: false
      t.string :reason_code
      t.string :idempotency_key_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.timestamptz :revised_at, null: false
      t.timestamptz :retain_until
      t.timestamptz :erased_at

      t.timestamps
    end

    add_check_constraint :ticketing_registration_answer_revisions,
      "revision_number > 0",
      name: "ticketing_registration_answer_revisions_positive_number_check"
    add_check_constraint :ticketing_registration_answer_revisions,
      "source IN ('attendee_correction','manager_correction')",
      name: "ticketing_registration_answer_revisions_source_check"
    add_check_constraint :ticketing_registration_answer_revisions,
      "source <> 'manager_correction' OR reason_code IS NOT NULL",
      name: "ticketing_registration_answer_revisions_manager_reason_check"
    add_check_constraint :ticketing_registration_answer_revisions,
      "reason_code IS NULL OR reason_code IN " \
        "('attendee_request','data_quality','legal_requirement','accessibility_correction')",
      name: "ticketing_registration_answer_revisions_reason_code_check"
    add_check_constraint :ticketing_registration_answer_revisions,
      "(erased_at IS NULL AND answer_ciphertext IS NOT NULL) OR " \
        "(erased_at IS NOT NULL AND answer_ciphertext IS NULL)",
      name: "ticketing_registration_answer_revisions_erasure_check"
    add_check_constraint :ticketing_registration_answer_revisions,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_registration_answer_revisions_digest_check"

    add_index :ticketing_registration_answer_revisions,
      %i[registration_answer_id revision_number],
      unique: true,
      name: "idx_registration_answer_revisions_answer_number"
    add_index :ticketing_registration_answer_revisions,
      :idempotency_key_digest,
      unique: true,
      name: "idx_registration_answer_revisions_idempotency"
    add_index :ticketing_registration_answer_revisions, %i[registration_answer_id revised_at]

    add_foreign_key :ticketing_registration_answer_revisions,
                    :ticketing_registration_answers,
                    column: :registration_answer_id
    add_foreign_key :ticketing_registration_answer_revisions,
                    :core_users,
                    column: :revised_by_id
  end
end
