# frozen_string_literal: true

class CreateOrdersGiftPurchases < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_gift_purchases, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :order_item_id, null: false
      t.uuid :client_line_id
      t.uuid :recipient_user_id, null: false
      t.text :recipient_phone_ciphertext, null: false
      t.string :recipient_phone_digest, limit: 64, null: false
      t.text :recipient_email_ciphertext
      t.string :recipient_email_digest, limit: 64
      t.text :note_ciphertext
      t.text :token_ciphertext, null: false
      t.string :token_digest, limit: 64, null: false
      t.string :status, null: false, default: "pending_payment"
      t.string :delivery_status, null: false, default: "pending"
      t.integer :delivery_revision, null: false, default: 0
      t.timestamptz :expires_at, null: false
      t.timestamptz :ready_at
      t.timestamptz :delivered_at
      t.timestamptz :claimed_at
      t.timestamptz :expired_at
      t.timestamptz :revoked_at

      t.timestamps
    end

    add_check_constraint :orders_gift_purchases,
      "status IN ('pending_payment','ready','pending_recipient_consent','claimed','expired','revoked')",
      name: "orders_gift_purchases_status_check"
    add_check_constraint :orders_gift_purchases,
      "delivery_status IN ('pending','sent','partial','failed')",
      name: "orders_gift_purchases_delivery_status_check"
    add_check_constraint :orders_gift_purchases, "delivery_revision >= 0",
      name: "orders_gift_purchases_delivery_revision_check"
    add_check_constraint :orders_gift_purchases,
      "recipient_phone_digest ~ '^[0-9a-f]{64}$' AND token_digest ~ '^[0-9a-f]{64}$'",
      name: "orders_gift_purchases_digest_check"
    add_check_constraint :orders_gift_purchases,
      "(recipient_email_ciphertext IS NULL) = (recipient_email_digest IS NULL) AND " \
        "(recipient_email_digest IS NULL OR recipient_email_digest ~ '^[0-9a-f]{64}$')",
      name: "orders_gift_purchases_email_digest_check"
    add_check_constraint :orders_gift_purchases,
      "(status = 'pending_payment' AND ready_at IS NULL AND claimed_at IS NULL AND " \
        "expired_at IS NULL AND revoked_at IS NULL) OR " \
        "(status IN ('ready', 'pending_recipient_consent') AND ready_at IS NOT NULL AND claimed_at IS NULL AND " \
        "expired_at IS NULL AND revoked_at IS NULL) OR " \
        "(status = 'claimed' AND ready_at IS NOT NULL AND claimed_at IS NOT NULL AND " \
        "expired_at IS NULL AND revoked_at IS NULL) OR " \
        "(status = 'expired' AND expired_at IS NOT NULL AND revoked_at IS NULL) OR " \
        "(status = 'revoked' AND revoked_at IS NOT NULL)",
      name: "orders_gift_purchases_lifecycle_check"

    add_index :orders_gift_purchases, :order_item_id, unique: true
    add_index :orders_gift_purchases, :token_digest, unique: true
    add_index :orders_gift_purchases, %i[status expires_at], name: "idx_orders_gift_purchases_expiry"
    add_index :orders_gift_purchases, %i[recipient_user_id created_at]

    add_foreign_key :orders_gift_purchases, :orders_order_items, column: :order_item_id
    add_foreign_key :orders_gift_purchases, :core_users, column: :recipient_user_id
  end
end
