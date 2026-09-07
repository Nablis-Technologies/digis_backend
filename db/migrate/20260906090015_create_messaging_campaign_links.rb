# frozen_string_literal: true

class CreateMessagingCampaignLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_links, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_id, null: false
      t.uuid :short_link_id, null: false
      t.string :channel, null: false
      t.string :name, null: false

      t.timestamps
    end

    add_check_constraint :messaging_campaign_links,
      "channel IN ('sms','email')",
      name: "messaging_campaign_links_channel_check"
    add_index :messaging_campaign_links, %i[campaign_id short_link_id],
      unique: true, name: "idx_messaging_campaign_links_identity"
    add_foreign_key :messaging_campaign_links,
      :messaging_campaigns, column: :campaign_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_links,
      :links_short_links, column: :short_link_id, on_delete: :restrict
  end
end
