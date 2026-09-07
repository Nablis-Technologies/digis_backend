# frozen_string_literal: true

class CreateMessagingCampaignContactListEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_contact_list_entries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_contact_list_id, null: false
      t.text :phone_number_ciphertext
      t.text :email_ciphertext
      t.text :first_name_ciphertext
      t.text :last_name_ciphertext
      t.string :phone_digest, limit: 64
      t.string :email_digest, limit: 64
      t.string :source
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_check_constraint :messaging_campaign_contact_list_entries,
      "phone_digest IS NOT NULL OR email_digest IS NOT NULL",
      name: "messaging_campaign_contact_list_entries_address_check"
    add_check_constraint :messaging_campaign_contact_list_entries,
      "(phone_digest IS NULL OR phone_digest ~ '^[0-9a-f]{64}$') AND " \
      "(email_digest IS NULL OR email_digest ~ '^[0-9a-f]{64}$')",
      name: "messaging_campaign_contact_list_entries_digest_check"
    add_check_constraint :messaging_campaign_contact_list_entries,
      "status IN ('active','removed')",
      name: "messaging_campaign_contact_list_entries_status_check"

    add_index :messaging_campaign_contact_list_entries,
      %i[campaign_contact_list_id phone_digest], unique: true,
      where: "phone_digest IS NOT NULL",
      name: "idx_messaging_campaign_contact_entries_phone"
    add_index :messaging_campaign_contact_list_entries,
      %i[campaign_contact_list_id email_digest], unique: true,
      where: "email_digest IS NOT NULL",
      name: "idx_messaging_campaign_contact_entries_email"
    add_index :messaging_campaign_contact_list_entries,
      %i[campaign_contact_list_id status id],
      name: "idx_messaging_campaign_contact_entries_status"
    add_foreign_key :messaging_campaign_contact_list_entries,
      :messaging_campaign_contact_lists, column: :campaign_contact_list_id, on_delete: :cascade
  end
end
