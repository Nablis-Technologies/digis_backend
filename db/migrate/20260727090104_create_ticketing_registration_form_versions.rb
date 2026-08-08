# frozen_string_literal: true

class CreateTicketingRegistrationFormVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_registration_form_versions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_form_id, null: false
      t.integer :version, null: false
      t.string :status, null: false, default: "draft"
      t.uuid :published_by_id
      t.timestamptz :published_at

      t.timestamps
    end

    add_check_constraint :ticketing_registration_form_versions,
      "version > 0",
      name: "ticketing_registration_form_versions_positive_version_check"
    add_check_constraint :ticketing_registration_form_versions,
      "status IN ('draft','published','retired')",
      name: "ticketing_registration_form_versions_status_check"
    add_check_constraint :ticketing_registration_form_versions,
      "(status = 'draft' AND published_by_id IS NULL AND published_at IS NULL) OR " \
        "(status IN ('published','retired') AND published_by_id IS NOT NULL AND published_at IS NOT NULL)",
      name: "ticketing_registration_form_versions_publish_metadata_check"

    add_index :ticketing_registration_form_versions,
      %i[registration_form_id version],
      unique: true,
      name: "idx_registration_form_versions_form_version"
    add_index :ticketing_registration_form_versions,
      :registration_form_id,
      unique: true,
      where: "status = 'published'",
      name: "idx_registration_form_versions_one_published"
    add_index :ticketing_registration_form_versions, %i[registration_form_id status]

    add_foreign_key :ticketing_registration_form_versions,
                    :ticketing_registration_forms,
                    column: :registration_form_id
    add_foreign_key :ticketing_registration_form_versions,
                    :core_users,
                    column: :published_by_id
  end
end
