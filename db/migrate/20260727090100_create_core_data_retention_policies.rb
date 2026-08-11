# frozen_string_literal: true

class CreateCoreDataRetentionPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :core_data_retention_policies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :category, null: false
      t.string :jurisdiction_code
      t.integer :version, null: false
      t.integer :retention_days
      t.string :action, null: false
      t.string :status, null: false, default: "draft"
      t.timestamptz :effective_at
      t.uuid :created_by_id, null: false

      t.timestamps
    end

    add_check_constraint :core_data_retention_policies,
      "category IN ('registration_free_text','registration_structured','consent_evidence','security_audit','financial_record')",
      name: "core_retention_policies_category_check"
    add_check_constraint :core_data_retention_policies,
      "version > 0",
      name: "core_retention_policies_version_check"
    add_check_constraint :core_data_retention_policies,
      "retention_days IS NULL OR retention_days > 0",
      name: "core_retention_policies_days_check"
    add_check_constraint :core_data_retention_policies,
      "action IN ('erase_payload','retain')",
      name: "core_retention_policies_action_check"
    add_check_constraint :core_data_retention_policies,
      "status IN ('draft','active','retired')",
      name: "core_retention_policies_status_check"
    add_check_constraint :core_data_retention_policies,
      "(action = 'retain' OR retention_days IS NOT NULL) AND " \
        "(status <> 'active' OR effective_at IS NOT NULL)",
      name: "core_retention_policies_configuration_check"

    add_index :core_data_retention_policies,
      "category, COALESCE(jurisdiction_code, ''), version",
      unique: true,
      name: "idx_core_retention_policies_scope_version"
    add_index :core_data_retention_policies,
      "category, COALESCE(jurisdiction_code, '')",
      unique: true,
      where: "status = 'active'",
      name: "idx_core_retention_policies_one_active"
    add_index :core_data_retention_policies,
      %i[category jurisdiction_code status effective_at]
    add_foreign_key :core_data_retention_policies,
      :core_users,
      column: :created_by_id
  end
end
