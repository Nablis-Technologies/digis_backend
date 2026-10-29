# frozen_string_literal: true

class CreateMessagingCampaignCreditAllocations < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_credit_allocations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_id, null: false
      t.uuid :delivery_id, null: false
      t.uuid :credit_reservation_id, null: false
      t.bigint :quantity, null: false
      t.string :status, null: false, default: "allocated"
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :resolution_code
      t.timestamptz :resolved_at

      t.timestamps
    end

    add_check_constraint :messaging_campaign_credit_allocations,
      "quantity > 0",
      name: "messaging_campaign_credit_allocations_quantity_check"
    add_check_constraint :messaging_campaign_credit_allocations,
      "status IN ('allocated','consumed','released','refunded')",
      name: "messaging_campaign_credit_allocations_status_check"
    add_check_constraint :messaging_campaign_credit_allocations,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_credit_allocations_digest_check"
    add_check_constraint :messaging_campaign_credit_allocations,
      "(status = 'allocated' AND resolved_at IS NULL) OR (status <> 'allocated' AND resolved_at IS NOT NULL)",
      name: "messaging_campaign_credit_allocations_resolution_check"

    add_index :messaging_campaign_credit_allocations, :delivery_id,
      unique: true, name: "idx_messaging_campaign_credit_allocations_delivery"
    add_index :messaging_campaign_credit_allocations,
      %i[credit_reservation_id status id],
      name: "idx_messaging_campaign_credit_allocations_hold"
    add_foreign_key :messaging_campaign_credit_allocations,
      :messaging_campaigns, column: :campaign_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_credit_allocations,
      :messaging_campaign_deliveries, column: :delivery_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_credit_allocations,
      :messaging_credit_reservations, column: :credit_reservation_id, on_delete: :restrict
  end
end
