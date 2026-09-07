# frozen_string_literal: true

class CreateMessagingCampaignContactLists < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_contact_lists, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :created_by_id, null: false
      t.string :name, null: false
      t.string :status, null: false, default: "active"
      t.integer :version, null: false, default: 1

      t.timestamps
    end

    add_check_constraint :messaging_campaign_contact_lists,
      "status IN ('active','archived')",
      name: "messaging_campaign_contact_lists_status_check"
    add_check_constraint :messaging_campaign_contact_lists,
      "version > 0",
      name: "messaging_campaign_contact_lists_version_check"

    add_index :messaging_campaign_contact_lists, %i[organization_id name],
      unique: true, name: "idx_messaging_campaign_contact_lists_name"
    add_foreign_key :messaging_campaign_contact_lists, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_campaign_contact_lists, :core_users,
      column: :created_by_id, on_delete: :restrict
  end
end
