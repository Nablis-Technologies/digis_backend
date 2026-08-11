# frozen_string_literal: true

class CreateCoreDataRetentionHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :core_data_retention_holds, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id
      t.uuid :registration_id
      t.uuid :user_id
      t.string :category
      t.string :reason_code, null: false
      t.uuid :placed_by_id, null: false
      t.timestamptz :starts_at, null: false
      t.timestamptz :expires_at
      t.uuid :released_by_id
      t.timestamptz :released_at
      t.string :idempotency_key, null: false

      t.timestamps
    end

    add_check_constraint :core_data_retention_holds,
      "num_nonnulls(event_id, registration_id, user_id) = 1",
      name: "core_retention_holds_one_scope_check"
    add_check_constraint :core_data_retention_holds,
      "category IS NULL OR category IN ('registration_free_text','registration_structured','consent_evidence','security_audit','financial_record')",
      name: "core_retention_holds_category_check"
    add_check_constraint :core_data_retention_holds,
      "reason_code IN ('legal_hold','litigation','regulatory_investigation','security_incident','security_hold','fraud_investigation','law_enforcement_request')",
      name: "core_retention_holds_reason_check"
    add_check_constraint :core_data_retention_holds,
      "expires_at IS NULL OR expires_at > starts_at",
      name: "core_retention_holds_window_check"
    add_check_constraint :core_data_retention_holds,
      "(released_at IS NULL AND released_by_id IS NULL) OR " \
        "(released_at IS NOT NULL AND released_by_id IS NOT NULL)",
      name: "core_retention_holds_release_pair_check"
    add_check_constraint :core_data_retention_holds,
      "released_at IS NULL OR released_at >= starts_at",
      name: "core_retention_holds_release_time_check"

    add_index :core_data_retention_holds, :idempotency_key, unique: true
    add_index :core_data_retention_holds, %i[event_id category released_at]
    add_index :core_data_retention_holds, %i[registration_id category released_at]
    add_index :core_data_retention_holds, %i[user_id category released_at]

    add_foreign_key :core_data_retention_holds, :events_events, column: :event_id
    add_foreign_key :core_data_retention_holds, :ticketing_registrations, column: :registration_id
    add_foreign_key :core_data_retention_holds, :core_users, column: :user_id
    add_foreign_key :core_data_retention_holds, :core_users, column: :placed_by_id
    add_foreign_key :core_data_retention_holds, :core_users, column: :released_by_id
  end
end
