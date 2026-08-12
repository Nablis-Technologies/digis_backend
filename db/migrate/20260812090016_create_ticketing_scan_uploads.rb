# frozen_string_literal: true

class CreateTicketingScanUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_scan_uploads, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :scanner_device_assignment_id, null: false
      t.uuid :client_upload_id, null: false
      t.timestamptz :received_at, null: false
      t.timestamptz :completed_at

      t.timestamps
    end

    add_check_constraint :ticketing_scan_uploads,
      "completed_at IS NULL OR completed_at >= received_at",
      name: "ticketing_scan_uploads_completion_check"
    add_index :ticketing_scan_uploads,
              %i[scanner_device_assignment_id client_upload_id],
              unique: true
    add_index :ticketing_scan_uploads, %i[scanner_device_assignment_id received_at]

    add_foreign_key :ticketing_scan_uploads,
                    :ticketing_scanner_device_assignments,
                    column: :scanner_device_assignment_id
  end
end
