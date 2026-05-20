class CreateCoreAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :core_audit_logs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :auditable, polymorphic: true, null: false, type: :uuid, index: false
      t.string :action, null: false
      t.jsonb :audited_changes, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.references :actor, polymorphic: true, type: :uuid, index: false
      t.string :request_uuid
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_index :core_audit_logs, %i[auditable_type auditable_id], name: "index_core_audit_logs_on_auditable"
    add_index :core_audit_logs, %i[actor_type actor_id], name: "index_core_audit_logs_on_actor"
    add_index :core_audit_logs, :request_uuid
    add_index :core_audit_logs, :created_at
    add_index :core_audit_logs, :action
  end
end
