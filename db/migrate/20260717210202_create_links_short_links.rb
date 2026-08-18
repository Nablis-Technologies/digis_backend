# frozen_string_literal: true

class CreateLinksShortLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :links_short_links, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :slug, null: false
      t.string :target_type
      t.uuid :target_id
      t.text :custom_url
      t.uuid :creator_id
      t.boolean :canonical, null: false, default: false
      t.timestamptz :expires_at
      t.bigint :max_clicks
      t.bigint :click_count, null: false, default: 0
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign

      t.timestamps
    end

    add_index :links_short_links, "lower(slug)", unique: true,
              name: "idx_links_short_links_lower_slug"
    add_index :links_short_links, %i[target_type target_id]
    add_index :links_short_links, :creator_id
    add_index :links_short_links, %i[target_type target_id], unique: true,
              where: "canonical = TRUE AND target_type IS NOT NULL",
              name: "idx_links_short_links_canonical_target"

    add_check_constraint :links_short_links,
      "target_type IS NULL OR target_type IN ('event','ticket','organization')",
      name: "links_short_links_target_type_check"
    add_check_constraint :links_short_links,
      "((target_type IS NOT NULL AND target_id IS NOT NULL AND custom_url IS NULL) OR " \
      "(target_type IS NULL AND target_id IS NULL AND custom_url IS NOT NULL))",
      name: "links_short_links_target_xor_check"
    add_check_constraint :links_short_links,
      "custom_url IS NULL OR custom_url LIKE 'https://%'",
      name: "links_short_links_https_url_check"
    add_check_constraint :links_short_links,
      "(max_clicks IS NULL OR max_clicks > 0) AND click_count >= 0 AND " \
      "(max_clicks IS NULL OR click_count <= max_clicks)",
      name: "links_short_links_click_bounds_check"

    add_foreign_key :links_short_links, :core_users, column: :creator_id
  end
end
