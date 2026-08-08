# frozen_string_literal: true

class CreateTicketingRegistrationFormSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registration_form_submissions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_id, null: false
      t.uuid :registration_form_version_id, null: false
      t.uuid :submitted_by_user_id, null: false
      t.timestamptz :submitted_at, null: false

      t.timestamps
    end

    add_index :ticketing_registration_form_submissions,
      %i[registration_id registration_form_version_id],
      unique: true,
      name: "idx_registration_submissions_registration_version"
    add_index :ticketing_registration_form_submissions, :registration_form_version_id
    add_index :ticketing_registration_form_submissions, :submitted_by_user_id

    add_foreign_key :ticketing_registration_form_submissions,
                    :ticketing_registrations,
                    column: :registration_id
    add_foreign_key :ticketing_registration_form_submissions,
                    :ticketing_registration_form_versions,
                    column: :registration_form_version_id
    add_foreign_key :ticketing_registration_form_submissions,
                    :core_users,
                    column: :submitted_by_user_id
  end
end
