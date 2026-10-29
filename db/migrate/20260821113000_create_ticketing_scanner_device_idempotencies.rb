# frozen_string_literal: true

class CreateTicketingScannerDeviceIdempotencies < ActiveRecord::Migration[8.1]
  OPERATIONS = %w[revoke].freeze

  def change
    create_table :ticketing_scanner_device_idempotencies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :scanner_device_id, null: false
      t.string :operation, null: false
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_scanner_device_idempotencies,
      "operation IN (#{OPERATIONS.map { |value| connection.quote(value) }.join(",")})",
      name: "ticketing_scanner_device_idempotencies_operation_check"
    add_check_constraint :ticketing_scanner_device_idempotencies,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_scanner_device_idempotencies_digest_check"

    add_index :ticketing_scanner_device_idempotencies,
              %i[operation idempotency_key_digest],
              unique: true,
              name: "idx_scanner_device_idempotencies_operation_key"
    add_index :ticketing_scanner_device_idempotencies, :scanner_device_id

    add_foreign_key :ticketing_scanner_device_idempotencies,
                    :ticketing_scanner_devices,
                    column: :scanner_device_id
  end
end
