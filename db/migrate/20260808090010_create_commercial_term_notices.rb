class CreateCommercialTermNotices < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_term_notices, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :fee_schedule_version_id, null: false
      t.uuid :legal_document_version_id, null: false
      t.string :delivery_method, null: false, default: "in_app"
      t.string :status, null: false, default: "pending"
      t.string :evidence_digest, null: false, limit: 64
      t.timestamptz :available_at, null: false
      t.timestamptz :delivered_at
      t.timestamptz :failed_at
      t.string :idempotency_key_digest, null: false, limit: 64
      t.timestamps
    end

    add_index :commercial_term_notices,
              %i[organization_id fee_schedule_version_id delivery_method],
              unique: true,
              name: "idx_commercial_term_notices_unique_delivery"
    add_index :commercial_term_notices, %i[organization_id status available_at],
              name: "idx_commercial_term_notices_on_organization_status"
    add_check_constraint :commercial_term_notices,
      "delivery_method IN ('in_app')",
      name: "commercial_term_notices_delivery_method_check"
    add_check_constraint :commercial_term_notices,
      "status IN ('pending','delivered','failed')",
      name: "commercial_term_notices_status_check"
    add_check_constraint :commercial_term_notices,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "commercial_term_notices_evidence_check"
    add_check_constraint :commercial_term_notices,
      "(status = 'delivered' AND delivered_at IS NOT NULL AND failed_at IS NULL) OR " \
      "(status = 'failed' AND failed_at IS NOT NULL AND delivered_at IS NULL) OR " \
      "(status = 'pending' AND delivered_at IS NULL AND failed_at IS NULL)",
      name: "commercial_term_notices_status_metadata_check"

    add_foreign_key :commercial_term_notices, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :commercial_term_notices, :commercial_fee_schedule_versions,
                    column: :fee_schedule_version_id, on_delete: :restrict
    add_foreign_key :commercial_term_notices, :legal_document_versions,
                    column: :legal_document_version_id, on_delete: :restrict
  end
end
