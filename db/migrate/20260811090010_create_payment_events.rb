# frozen_string_literal: true

class CreatePaymentEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_payment_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :payment_id
      t.string :provider, null: false
      t.string :provider_event_id, null: false
      t.string :event_type, null: false
      t.string :status, null: false, default: "received"
      t.jsonb :payload, null: false, default: {}
      t.string :payload_digest, limit: 64, null: false
      t.timestamptz :occurred_at
      t.timestamptz :received_at, null: false
      t.timestamptz :processed_at
      t.string :processing_error

      t.timestamps
    end

    add_index :orders_payment_events, %i[provider provider_event_id],
              unique: true,
              name: "idx_payment_events_on_provider_event"
    add_index :orders_payment_events, %i[status received_at],
              name: "idx_payment_events_on_status_and_received"
    add_index :orders_payment_events, :payment_id,
              name: "idx_payment_events_on_payment"

    add_check_constraint :orders_payment_events,
      "btrim(provider) <> '' AND btrim(provider_event_id) <> '' AND btrim(event_type) <> ''",
      name: "orders_payment_events_identity_check"
    add_check_constraint :orders_payment_events,
      "status IN ('received','processing','processed','failed','ignored')",
      name: "orders_payment_events_status_check"
    add_check_constraint :orders_payment_events,
      "payload_digest ~ '^[0-9a-f]{64}$'",
      name: "orders_payment_events_payload_digest_check"
    add_check_constraint :orders_payment_events,
      "(status = 'processed' AND processed_at IS NOT NULL) OR " \
      "(status <> 'processed')",
      name: "orders_payment_events_processed_state_check"

    add_foreign_key :orders_payment_events, :orders_payments,
                    column: :payment_id, on_delete: :restrict
  end
end
