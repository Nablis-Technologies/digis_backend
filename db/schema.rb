# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_26_165147) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "core_audit_logs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_type"
    t.uuid "auditable_id", null: false
    t.string "auditable_type", null: false
    t.jsonb "audited_changes", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.jsonb "metadata", default: {}, null: false
    t.string "request_uuid"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["action"], name: "index_core_audit_logs_on_action"
    t.index ["actor_type", "actor_id"], name: "index_core_audit_logs_on_actor"
    t.index ["auditable_type", "auditable_id"], name: "index_core_audit_logs_on_auditable"
    t.index ["created_at"], name: "index_core_audit_logs_on_created_at"
    t.index ["request_uuid"], name: "index_core_audit_logs_on_request_uuid"
  end

  create_table "core_permissions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "action", limit: 50, null: false
    t.boolean "active", default: true, null: false
    t.string "code", limit: 100, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.string "namespace", limit: 50, default: "core", null: false
    t.string "resource", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_core_permissions_on_active"
    t.index ["code"], name: "index_core_permissions_on_code", unique: true
    t.index ["namespace"], name: "index_core_permissions_on_namespace"
    t.index ["resource", "action", "namespace"], name: "index_core_permissions_on_resource_action_namespace", unique: true
    t.index ["resource"], name: "index_core_permissions_on_resource"
  end

  create_table "core_refresh_tokens", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device_id"
    t.datetime "expires_at", null: false
    t.string "ip_address"
    t.string "jti", null: false
    t.boolean "revoked", default: false, null: false
    t.datetime "revoked_at"
    t.string "token_fingerprint", null: false
    t.string "token_hash", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.uuid "user_id", null: false
    t.index ["device_id"], name: "index_core_refresh_tokens_on_device_id"
    t.index ["expires_at"], name: "index_core_refresh_tokens_on_expires_at"
    t.index ["jti"], name: "index_core_refresh_tokens_on_jti", unique: true
    t.index ["revoked"], name: "index_core_refresh_tokens_on_revoked"
    t.index ["token_fingerprint"], name: "index_core_refresh_tokens_on_token_fingerprint", unique: true
    t.index ["user_id"], name: "index_core_refresh_tokens_on_user_id"
  end

  create_table "core_reviews", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "context", default: "default", null: false
    t.datetime "created_at", null: false
    t.jsonb "feedback", default: {}, null: false
    t.uuid "reviewable_id", null: false
    t.string "reviewable_type", null: false
    t.datetime "reviewed_at"
    t.uuid "reviewed_by_id"
    t.string "reviewed_by_type"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["reviewable_type", "reviewable_id", "context"], name: "idx_core_reviews_resource_context"
    t.index ["reviewed_by_type", "reviewed_by_id"], name: "idx_core_reviews_reviewer"
    t.index ["status"], name: "index_core_reviews_on_status"
  end

  create_table "core_role_permissions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "permission_id", null: false
    t.uuid "role_id", null: false
    t.datetime "updated_at", null: false
    t.index ["permission_id"], name: "index_core_role_permissions_on_permission_id"
    t.index ["role_id", "permission_id"], name: "index_core_role_permissions_on_role_id_and_permission_id", unique: true
    t.index ["role_id"], name: "index_core_role_permissions_on_role_id"
  end

  create_table "core_roles", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", limit: 50, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.string "name", limit: 100, null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_core_roles_on_active"
    t.index ["code"], name: "index_core_roles_on_code", unique: true
  end

  create_table "core_user_roles", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "assigned_by_id"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.uuid "role_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["assigned_by_id"], name: "index_core_user_roles_on_assigned_by_id"
    t.index ["expires_at"], name: "index_core_user_roles_on_expires_at"
    t.index ["role_id"], name: "index_core_user_roles_on_role_id"
    t.index ["user_id", "role_id"], name: "index_core_user_roles_on_user_id_and_role_id", unique: true
    t.index ["user_id"], name: "index_core_user_roles_on_user_id"
  end

  create_table "core_users", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "deactivated_reason"
    t.string "email", limit: 150
    t.string "password_digest"
    t.string "phone", limit: 30
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["deactivated_at"], name: "index_core_users_on_deactivated_at"
    t.index ["email"], name: "index_core_users_on_email", unique: true
    t.index ["phone"], name: "index_core_users_on_phone", unique: true
  end

  create_table "events_categories", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_events_categories_on_active"
    t.index ["name"], name: "index_events_categories_on_name"
    t.index ["slug"], name: "index_events_categories_on_slug", unique: true
  end

  create_table "organizations_memberships", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.integer "role", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["organization_id"], name: "idx_one_owner_per_org", unique: true, where: "(role = 0)"
    t.index ["organization_id"], name: "index_organizations_memberships_on_organization_id"
    t.index ["user_id", "organization_id"], name: "idx_org_memberships_on_user_and_org", unique: true
    t.index ["user_id"], name: "index_organizations_memberships_on_user_id"
  end

  create_table "organizations_organizations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_organizations_on_slug", unique: true
  end

  add_foreign_key "core_refresh_tokens", "core_users", column: "user_id"
  add_foreign_key "core_role_permissions", "core_permissions", column: "permission_id"
  add_foreign_key "core_role_permissions", "core_roles", column: "role_id"
  add_foreign_key "core_user_roles", "core_roles", column: "role_id"
  add_foreign_key "core_user_roles", "core_users", column: "assigned_by_id"
  add_foreign_key "core_user_roles", "core_users", column: "user_id"
  add_foreign_key "organizations_memberships", "core_users", column: "user_id"
  add_foreign_key "organizations_memberships", "organizations_organizations", column: "organization_id"
end
