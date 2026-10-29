# frozen_string_literal: true

class CreateMessagingCampaignTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_templates, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id
      t.uuid :created_by_id
      t.string :name, null: false
      t.string :channel, null: false
      t.string :status, null: false, default: "draft"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :messaging_campaign_templates,
      "channel IN ('sms','email')",
      name: "messaging_campaign_templates_channel_check"
    add_check_constraint :messaging_campaign_templates,
      "status IN ('draft','active','retired')",
      name: "messaging_campaign_templates_status_check"
    add_check_constraint :messaging_campaign_templates,
      "jsonb_typeof(metadata) = 'object'",
      name: "messaging_campaign_templates_metadata_check"

    add_index :messaging_campaign_templates, %i[organization_id channel name],
      unique: true, nulls_not_distinct: true,
      name: "idx_messaging_campaign_templates_scope_name"
    add_foreign_key :messaging_campaign_templates, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_campaign_templates, :core_users,
      column: :created_by_id, on_delete: :restrict
  end
end
