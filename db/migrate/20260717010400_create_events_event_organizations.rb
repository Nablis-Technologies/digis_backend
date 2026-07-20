# frozen_string_literal: true

class CreateEventsEventOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :events_event_organizations, id: false do |t|
      t.uuid :id, null: false, primary_key: true, default: -> { "gen_random_uuid()" }
      # Business discriminator: co_organizer, venue_partner, promoter, sponsor.
      t.string :type, null: false
      t.uuid :event_id, null: false
      t.uuid :organization_id, null: false
      t.string :role, null: false, default: "collaborator"
      t.string :status, null: false, default: "active"
      t.timestamptz :invited_at
      t.timestamptz :accepted_at
      t.timestamps

      t.index [ :event_id, :organization_id ], unique: true
      t.index :organization_id
    end

    add_foreign_key :events_event_organizations, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_event_organizations, :organizations_organizations,
                    column: :organization_id, on_delete: :cascade

    add_check_constraint :events_event_organizations,
                         "type IN ('co_organizer','venue_partner','promoter','sponsor')",
                         name: "chk_event_organizations_type"
    add_check_constraint :events_event_organizations,
                         "status IN ('pending','active','revoked')",
                         name: "chk_event_organizations_status"
    add_check_constraint :events_event_organizations,
                         "role <> 'primary_owner'",
                         name: "chk_event_organizations_no_primary_owner"
  end
end
