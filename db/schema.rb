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

ActiveRecord::Schema[8.1].define(version: 2026_07_17_010900) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "core_audit_logs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_type"
    t.string "audit_key", null: false
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
    t.index ["audit_key"], name: "index_core_audit_logs_on_audit_key", unique: true
    t.index ["auditable_type", "auditable_id"], name: "index_core_audit_logs_on_auditable"
    t.index ["created_at"], name: "index_core_audit_logs_on_created_at"
    t.index ["request_uuid"], name: "index_core_audit_logs_on_request_uuid"
  end

  create_table "core_follows", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "followable_id", null: false
    t.string "followable_type", null: false
    t.datetime "followed_at", null: false
    t.uuid "follower_id", null: false
    t.datetime "updated_at", null: false
    t.index ["followable_id", "followable_type"], name: "index_follows_followable"
    t.index ["follower_id", "followable_id", "followable_type"], name: "index_follows_uniqueness", unique: true
    t.index ["follower_id"], name: "index_core_follows_on_follower_id"
  end

  create_table "core_outbox_events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "aggregate_id", null: false
    t.string "aggregate_type", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "available_at", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "idempotency_key", null: false
    t.string "last_error_code"
    t.datetime "locked_at"
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "published_at"
    t.string "topic", null: false
    t.datetime "updated_at", null: false
    t.index ["aggregate_type", "aggregate_id", "occurred_at"], name: "idx_on_aggregate_type_aggregate_id_occurred_at_dc800603ae"
    t.index ["event_type"], name: "index_core_outbox_events_on_event_type"
    t.index ["idempotency_key"], name: "index_core_outbox_events_on_idempotency_key", unique: true
    t.index ["published_at", "available_at", "id"], name: "idx_on_published_at_available_at_id_30dbfe6ec6"
    t.check_constraint "aggregate_type::text <> ''::text", name: "core_outbox_events_aggregate_type_nonblank"
    t.check_constraint "available_at >= occurred_at", name: "core_outbox_events_available_after_occurred"
    t.check_constraint "event_type::text <> ''::text", name: "core_outbox_events_event_type_nonblank"
    t.check_constraint "published_at IS NULL OR published_at >= occurred_at", name: "core_outbox_events_published_after_occurred"
    t.check_constraint "topic::text <> ''::text", name: "core_outbox_events_topic_nonblank"
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

  create_table "events_access_zones", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.uuid "event_date_id"
    t.uuid "event_id", null: false
    t.string "name", null: false
    t.integer "sort_order", default: 0, null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "code"], name: "index_access_zones_on_event_code", unique: true
    t.index ["event_id", "type", "active", "sort_order"], name: "index_access_zones_on_event_type_active_order"
    t.check_constraint "type::text = ANY (ARRAY['venue'::character varying::text, 'parking'::character varying::text])", name: "chk_access_zones_type"
  end

  create_table "events_artists", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "followers_count", default: 0, null: false
    t.jsonb "genres", default: []
    t.string "image_url"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "slug", null: false
    t.jsonb "social_links", default: {}
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false
    t.index ["active"], name: "index_events_artists_on_active"
    t.index ["genres"], name: "index_events_artists_on_genres", using: :gin
    t.index ["slug"], name: "index_events_artists_on_slug", unique: true
    t.index ["verified"], name: "index_events_artists_on_verified"
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

  create_table "events_event_categories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "category_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.uuid "event_id", null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["category_id"], name: "index_events_event_categories_on_category_id"
    t.index ["event_id", "category_id"], name: "index_events_event_categories_on_event_id_and_category_id", unique: true
    t.check_constraint "event_id IS NOT NULL AND category_id IS NOT NULL", name: "chk_event_categories_present"
  end

  create_table "events_event_dates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "doors_at", precision: nil
    t.datetime "ends_at", precision: nil, null: false
    t.uuid "event_id", null: false
    t.integer "held_venue_count", default: 0, null: false
    t.integer "issued_venue_count", default: 0, null: false
    t.string "name"
    t.string "source_key"
    t.datetime "starts_at", precision: nil, null: false
    t.string "status", default: "scheduled", null: false
    t.datetime "updated_at", null: false
    t.integer "venue_capacity"
    t.uuid "venue_id"
    t.index ["event_id", "source_key"], name: "index_events_event_dates_on_event_id_and_source_key", unique: true, where: "(source_key IS NOT NULL)"
    t.index ["event_id", "starts_at"], name: "index_events_event_dates_on_event_id_and_starts_at"
    t.index ["event_id"], name: "index_events_event_dates_on_event_id"
    t.check_constraint "doors_at IS NULL OR doors_at <= starts_at", name: "chk_event_dates_doors_before_starts"
    t.check_constraint "ends_at > starts_at", name: "chk_event_dates_ends_after_starts"
    t.check_constraint "held_venue_count >= 0 AND issued_venue_count >= 0", name: "chk_event_dates_counts_nonnegative"
  end

  create_table "events_event_media", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "alt_text"
    t.text "caption"
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.uuid "event_id", null: false
    t.integer "position", default: 0, null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_event_media_on_created_by"
    t.index ["event_id", "type", "position"], name: "index_event_media_on_event_type_position", unique: true
    t.check_constraint "\"position\" >= 0", name: "chk_event_media_position"
    t.check_constraint "type::text <> 'cover'::text OR \"position\" = 0", name: "chk_event_media_cover_position"
    t.check_constraint "type::text = ANY (ARRAY['cover'::character varying, 'gallery'::character varying]::text[])", name: "chk_event_media_type"
  end

  create_table "events_event_organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.uuid "event_id", null: false
    t.datetime "invited_at", precision: nil
    t.uuid "organization_id", null: false
    t.string "role", default: "collaborator", null: false
    t.string "status", default: "active", null: false
    t.string "type", null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["event_id", "organization_id"], name: "idx_on_event_id_organization_id_ee33770ea4", unique: true
    t.index ["organization_id"], name: "index_events_event_organizations_on_organization_id"
    t.check_constraint "role::text <> 'primary_owner'::text", name: "chk_event_organizations_no_primary_owner"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'revoked'::character varying::text])", name: "chk_event_organizations_status"
    t.check_constraint "type::text = ANY (ARRAY['co_organizer'::character varying::text, 'venue_partner'::character varying::text, 'promoter'::character varying::text, 'sponsor'::character varying::text])", name: "chk_event_organizations_type"
  end

  create_table "events_event_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "artist_id"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "display_order", default: 0, null: false
    t.uuid "event_date_id"
    t.uuid "event_id", null: false
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "event_id"], name: "index_event_participants_on_artist_event", where: "(artist_id IS NOT NULL)"
    t.index ["event_id", "event_date_id", "display_order"], name: "index_event_participants_on_event_date_order"
    t.check_constraint "type::text = ANY (ARRAY['performer'::character varying::text, 'speaker'::character varying::text, 'host'::character varying::text, 'instructor'::character varying::text, 'panelist'::character varying::text, 'team'::character varying::text, 'guest'::character varying::text])", name: "chk_event_participants_type"
  end

  create_table "events_event_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", precision: nil, null: false
    t.uuid "event_id", null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["event_id"], name: "index_events_event_settings_on_event_id", unique: true
  end

  create_table "events_event_staff_assignments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.uuid "event_id", null: false
    t.datetime "expires_at", precision: nil
    t.uuid "organization_id", null: false
    t.string "role", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", precision: nil, null: false
    t.uuid "user_id", null: false
    t.index ["event_id", "user_id", "role"], name: "idx_on_event_id_user_id_role", unique: true
    t.index ["organization_id"], name: "index_events_event_staff_assignments_on_organization_id"
    t.index ["user_id"], name: "index_events_event_staff_assignments_on_user_id"
    t.check_constraint "role::text = ANY (ARRAY['manager'::character varying::text, 'staff'::character varying::text, 'scanner'::character varying::text, 'contractor'::character varying::text])", name: "chk_event_staff_assignments_role"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'suspended'::character varying::text, 'revoked'::character varying::text, 'expired'::character varying::text])", name: "chk_event_staff_assignments_status"
  end

  create_table "events_event_streams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "access_protection", null: false
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.uuid "event_date_id", null: false
    t.datetime "live_from", precision: nil, null: false
    t.datetime "live_until", precision: nil, null: false
    t.integer "max_concurrent_devices", default: 1, null: false
    t.string "provider", null: false
    t.string "provider_playback_id"
    t.string "provider_stream_id"
    t.datetime "replay_available_until", precision: nil
    t.boolean "replay_enabled", default: false, null: false
    t.string "status", default: "scheduled", null: false
    t.datetime "updated_at", null: false
    t.index ["event_date_id"], name: "index_event_streams_on_event_date", unique: true
    t.check_constraint "access_protection::text = ANY (ARRAY['public'::character varying::text, 'soft_gated'::character varying::text, 'signed'::character varying::text])", name: "chk_event_streams_access_protection"
    t.check_constraint "replay_available_until IS NOT NULL OR replay_enabled = false", name: "chk_event_streams_replay_until"
    t.check_constraint "status::text = ANY (ARRAY['scheduled'::character varying::text, 'live'::character varying::text, 'ended'::character varying::text, 'disabled'::character varying::text])", name: "chk_event_streams_status"
  end

  create_table "events_event_video_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "caption"
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.uuid "event_id", null: false
    t.integer "position", default: 0, null: false
    t.string "provider", default: "youtube", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["event_id", "position"], name: "index_event_video_links_on_event_position"
    t.check_constraint "provider::text = 'youtube'::text", name: "chk_event_video_links_provider"
  end

  create_table "events_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "cancelled_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.uuid "created_by_id", null: false
    t.string "currency", default: "ETB", null: false
    t.text "description"
    t.uuid "organization_id", null: false
    t.datetime "published_at", precision: nil
    t.string "slug", null: false
    t.string "status", default: "draft", null: false
    t.string "timezone", null: false
    t.string "title", null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "version", default: 1, null: false
    t.string "visibility", default: "private", null: false
    t.index "lower((slug)::text)", name: "idx_events_events_lower_slug", unique: true
    t.index ["created_by_id"], name: "index_events_events_on_created_by_id"
    t.index ["organization_id", "status"], name: "index_events_events_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_events_events_on_organization_id"
    t.check_constraint "cancelled_at IS NULL OR status::text = 'cancelled'::text", name: "chk_events_events_cancelled_at_requires_cancelled"
    t.check_constraint "currency::text ~ '^[A-Z]{3}$'::text", name: "chk_events_events_currency_iso4217"
    t.check_constraint "published_at IS NULL OR status::text = 'published'::text", name: "chk_events_events_published_at_requires_published"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'published'::character varying::text, 'cancelled'::character varying::text, 'completed'::character varying::text])", name: "chk_events_events_status"
    t.check_constraint "version >= 0", name: "chk_events_events_version_non_negative"
    t.check_constraint "visibility::text = ANY (ARRAY['private'::character varying::text, 'public'::character varying::text, 'unlisted'::character varying::text])", name: "chk_events_events_visibility"
  end

  create_table "events_recurrence_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.timestamp "dtstart_local", null: false
    t.integer "duration_seconds", null: false
    t.uuid "event_id", null: false
    t.jsonb "exdates", default: [], null: false
    t.datetime "generated_until", precision: nil
    t.jsonb "rdates", default: [], null: false
    t.text "rrule", null: false
    t.string "timezone", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_events_recurrence_rules_on_event_id", unique: true
    t.check_constraint "duration_seconds > 0", name: "chk_recurrence_duration_positive"
  end

  create_table "events_venues", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true
    t.string "address"
    t.jsonb "amenities", default: []
    t.integer "capacity"
    t.string "city"
    t.string "contact_email"
    t.string "contact_phone"
    t.string "country"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "followers_count", default: 0, null: false
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "slug", null: false
    t.jsonb "social_links", default: {}
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false
    t.string "website_url"
    t.index ["active"], name: "index_events_venues_on_active"
    t.index ["city"], name: "index_events_venues_on_city"
    t.index ["country"], name: "index_events_venues_on_country"
    t.index ["slug"], name: "index_events_venues_on_slug", unique: true
    t.index ["verified"], name: "index_events_venues_on_verified"
  end

  create_table "organizations_memberships", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.string "role", default: "staff", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["organization_id"], name: "idx_one_owner_per_org", unique: true, where: "((role)::text = 'owner'::text)"
    t.index ["organization_id"], name: "index_organizations_memberships_on_organization_id"
    t.index ["status"], name: "index_organizations_memberships_on_status"
    t.index ["user_id", "organization_id"], name: "idx_org_memberships_on_user_and_org", unique: true
    t.index ["user_id"], name: "index_organizations_memberships_on_user_id"
  end

  create_table "organizations_organizations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "address_line1"
    t.string "address_line2"
    t.string "category", null: false
    t.string "city"
    t.string "contact_email"
    t.string "contact_phone"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "estimated_audience"
    t.string "event_frequency"
    t.integer "events_count", default: 0, null: false
    t.integer "followers_count", default: 0, null: false
    t.string "name", null: false
    t.string "organizer_type", null: false
    t.string "region"
    t.string "slug", null: false
    t.jsonb "social_links", default: {}
    t.string "tin_number"
    t.datetime "updated_at", null: false
    t.string "website_url"
    t.index ["slug"], name: "index_organizations_organizations_on_slug", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "core_follows", "core_users", column: "follower_id"
  add_foreign_key "core_refresh_tokens", "core_users", column: "user_id"
  add_foreign_key "core_role_permissions", "core_permissions", column: "permission_id"
  add_foreign_key "core_role_permissions", "core_roles", column: "role_id"
  add_foreign_key "core_user_roles", "core_roles", column: "role_id"
  add_foreign_key "core_user_roles", "core_users", column: "assigned_by_id"
  add_foreign_key "core_user_roles", "core_users", column: "user_id"
  add_foreign_key "events_access_zones", "events_event_dates", column: "event_date_id", on_delete: :nullify
  add_foreign_key "events_access_zones", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_categories", "events_categories", column: "category_id", on_delete: :restrict
  add_foreign_key "events_event_categories", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_media", "core_users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "events_event_media", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_organizations", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_organizations", "organizations_organizations", column: "organization_id", on_delete: :cascade
  add_foreign_key "events_event_participants", "events_event_dates", column: "event_date_id", on_delete: :cascade
  add_foreign_key "events_event_participants", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_settings", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_staff_assignments", "core_users", column: "user_id", on_delete: :cascade
  add_foreign_key "events_event_staff_assignments", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_event_staff_assignments", "organizations_organizations", column: "organization_id", on_delete: :cascade
  add_foreign_key "events_event_streams", "events_event_dates", column: "event_date_id", on_delete: :cascade
  add_foreign_key "events_event_video_links", "core_users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "events_event_video_links", "events_events", column: "event_id", on_delete: :cascade
  add_foreign_key "events_events", "core_users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "events_events", "organizations_organizations", column: "organization_id", on_delete: :restrict
  add_foreign_key "organizations_memberships", "core_users", column: "user_id"
  add_foreign_key "organizations_memberships", "organizations_organizations", column: "organization_id"
end
