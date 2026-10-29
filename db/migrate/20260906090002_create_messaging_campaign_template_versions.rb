# frozen_string_literal: true

class CreateMessagingCampaignTemplateVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_template_versions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_template_id, null: false
      t.uuid :created_by_id
      t.integer :version, null: false
      t.string :locale, null: false
      t.text :subject_ciphertext
      t.text :body_ciphertext, null: false
      t.jsonb :variables, null: false, default: []
      t.string :status, null: false, default: "draft"

      t.timestamps
    end

    add_check_constraint :messaging_campaign_template_versions,
      "version > 0",
      name: "messaging_campaign_template_versions_version_check"
    add_check_constraint :messaging_campaign_template_versions,
      "status IN ('draft','active','retired')",
      name: "messaging_campaign_template_versions_status_check"
    add_check_constraint :messaging_campaign_template_versions,
      "jsonb_typeof(variables) = 'array'",
      name: "messaging_campaign_template_versions_variables_check"

    add_index :messaging_campaign_template_versions,
      %i[campaign_template_id version locale], unique: true,
      name: "idx_messaging_campaign_template_versions_identity"
    add_foreign_key :messaging_campaign_template_versions,
      :messaging_campaign_templates, column: :campaign_template_id, on_delete: :restrict
    add_foreign_key :messaging_campaign_template_versions, :core_users,
      column: :created_by_id, on_delete: :restrict
  end
end
