# frozen_string_literal: true

class CreateEventsEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events_events, id: false do |t|
      t.uuid :id, null: false, primary_key: true, default: -> { "gen_random_uuid()" }
      t.uuid :organization_id, null: false
      t.uuid :created_by_id, null: false
      t.string :slug, null: false
      t.string :title, null: false
      t.text :description
      t.string :status, null: false, default: "draft"
      t.string :visibility, null: false, default: "private"
      t.string :timezone, null: false
      t.string :currency, null: false, default: "ETB"
      t.integer :version, null: false, default: 1
      t.timestamptz :published_at
      t.timestamptz :cancelled_at
      t.timestamps

      t.index :organization_id
      t.index :created_by_id
      t.index [ :organization_id, :status ]
    end

    # Functional unique index enforces case-insensitive slug uniqueness.
    execute <<~SQL
      CREATE UNIQUE INDEX idx_events_events_lower_slug
        ON events_events (lower(slug));
    SQL

    add_foreign_key :events_events, :organizations_organizations,
                    column: :organization_id, on_delete: :restrict
    add_foreign_key :events_events, :core_users,
                    column: :created_by_id, on_delete: :restrict

    add_check_constraint :events_events, "version >= 0",
                         name: "chk_events_events_version_non_negative"
    add_check_constraint :events_events,
                         "status IN ('draft','published','cancelled','completed')",
                         name: "chk_events_events_status"
    add_check_constraint :events_events,
                         "visibility IN ('private','public','unlisted')",
                         name: "chk_events_events_visibility"
    add_check_constraint :events_events,
                         "currency ~ '^[A-Z]{3}$'",
                         name: "chk_events_events_currency_iso4217"
    add_check_constraint :events_events,
                         "published_at IS NULL OR status = 'published'",
                         name: "chk_events_events_published_at_requires_published"
    add_check_constraint :events_events,
                         "cancelled_at IS NULL OR status = 'cancelled'",
                         name: "chk_events_events_cancelled_at_requires_cancelled"
  end
end
