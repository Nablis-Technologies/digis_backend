# frozen_string_literal: true

class CreateTicketingTicketSuspensions < ActiveRecord::Migration[8.1]
  REASON_CODES = %w[suspected_fraud identity_review chargeback_review safety_review organizer_cancellation].freeze
  STATUSES = %w[active restored revoked_free cancelled_refunded expired].freeze
  RESOLUTION_REASONS = %w[review_cleared organizer_cancellation refund_succeeded review_deadline_expired].freeze

  def up
    create_table :ticketing_ticket_suspensions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.uuid :event_id, null: false
      t.uuid :initiated_by_id, null: false
      t.string :reason_code, null: false
      t.text :internal_note_ciphertext
      t.string :status, null: false, default: "active"
      t.timestamptz :review_deadline_at, null: false
      t.uuid :resolved_by_id
      t.string :resolution_reason
      t.timestamptz :resolved_at
      t.string :idempotency_key, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_ticket_suspensions,
      "status IN (#{quoted_values(STATUSES)})",
      name: "ticketing_ticket_suspensions_status_check"
    add_check_constraint :ticketing_ticket_suspensions,
      "reason_code IN (#{quoted_values(REASON_CODES)})",
      name: "ticketing_ticket_suspensions_reason_code_check"
    add_check_constraint :ticketing_ticket_suspensions,
      "resolution_reason IS NULL OR resolution_reason IN (#{quoted_values(RESOLUTION_REASONS)})",
      name: "ticketing_ticket_suspensions_resolution_reason_check"
    add_check_constraint :ticketing_ticket_suspensions,
      "(status = 'active' AND resolved_by_id IS NULL AND resolution_reason IS NULL AND resolved_at IS NULL) OR " \
      "(status <> 'active' AND resolved_by_id IS NOT NULL AND resolution_reason IS NOT NULL AND resolved_at IS NOT NULL)",
      name: "ticketing_ticket_suspensions_resolution_shape_check"

    add_index :ticketing_ticket_suspensions, :ticket_id,
      unique: true,
      where: "status = 'active'",
      name: "idx_one_active_ticket_suspension"
    add_index :ticketing_ticket_suspensions, :idempotency_key, unique: true
    add_index :ticketing_ticket_suspensions, %i[event_id status review_deadline_at],
      name: "idx_ticket_suspensions_review_deadline"

    add_foreign_key :ticketing_ticket_suspensions, :events_events, column: :event_id
    add_foreign_key :ticketing_ticket_suspensions, :core_users, column: :initiated_by_id
    add_foreign_key :ticketing_ticket_suspensions, :core_users, column: :resolved_by_id
    add_foreign_key :ticketing_ticket_suspensions, :ticketing_tickets, column: :ticket_id

    # The separate ticket and event FKs prevent missing parents. This composite
    # constraint additionally prevents a suspension from crossing event scope.
    execute <<~SQL
      ALTER TABLE ticketing_ticket_suspensions
        ADD CONSTRAINT ticketing_ticket_suspensions_ticket_event_fk
        FOREIGN KEY (ticket_id, event_id)
        REFERENCES ticketing_tickets (id, event_id)
        ON DELETE RESTRICT;
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE ticketing_ticket_suspensions
        DROP CONSTRAINT IF EXISTS ticketing_ticket_suspensions_ticket_event_fk;
    SQL
    drop_table :ticketing_ticket_suspensions
  end

  private

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(",")
  end
end
