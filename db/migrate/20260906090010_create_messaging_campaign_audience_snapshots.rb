# frozen_string_literal: true

class CreateMessagingCampaignAudienceSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_audience_snapshots, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_id, null: false
      t.string :status, null: false, default: "preparing"
      t.jsonb :source_spec, null: false, default: {}
      t.integer :processed_count, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.bigint :eligible_quantity, null: false, default: 0
      t.string :next_cursor
      t.string :failure_code
      t.timestamptz :started_at
      t.timestamptz :completed_at

      t.timestamps
    end

    add_check_constraint :messaging_campaign_audience_snapshots,
      "status IN ('preparing','ready','failed')",
      name: "messaging_campaign_audience_snapshots_status_check"
    add_check_constraint :messaging_campaign_audience_snapshots,
      "jsonb_typeof(source_spec) = 'object'",
      name: "messaging_campaign_audience_snapshots_source_spec_check"
    add_check_constraint :messaging_campaign_audience_snapshots,
      "processed_count >= 0 AND total_count >= 0 AND eligible_quantity >= 0 AND processed_count <= total_count",
      name: "messaging_campaign_audience_snapshots_counts_check"

    add_index :messaging_campaign_audience_snapshots, :campaign_id,
      unique: true, name: "idx_messaging_campaign_audience_snapshots_campaign"
    add_index :messaging_campaign_audience_snapshots, %i[status updated_at id],
      name: "idx_messaging_campaign_audience_snapshots_status"
    add_foreign_key :messaging_campaign_audience_snapshots,
      :messaging_campaigns, column: :campaign_id, on_delete: :cascade
  end
end
