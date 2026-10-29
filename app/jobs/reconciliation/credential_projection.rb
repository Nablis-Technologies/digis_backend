# frozen_string_literal: true

module Reconciliation
  # Repairs attendee-index rows from authoritative credential state. Revocations
  # always win, while admission-use rows remain append-only and untouched.
  class CredentialProjection
    include Reconciliation::Support

    def initialize(ticket_id:, batch_id:, now:)
      @ticket_id = ticket_id
      @batch_id = batch_id
      @now = now
    end

    def call
      ticket = load_ticket
      generation = ticket.current_credential_generation
      return unless generation

      credentials = generation.credentials
      use_counts = Ticketing::AdmissionUse.where(credential_id: credentials.map(&:id)).group(:credential_id).count
      credentials.each { |credential| repair(credential, generation:, use_count: use_counts.fetch(credential.id, 0)) }
    end

    private

    attr_reader :ticket_id, :batch_id, :now

    def load_ticket
      Ticketing::Ticket.includes(
        current_credential_generation: {
          credentials: [
            :credential_generation, :credential_revocation, :attendee_index_entry,
            :admission_slot, :holder_user,
            { ticket: [ :owner_user, { event_product: [ :ticket_type, { product_accesses: :event_date } ] } ] }
          ]
        }
      ).find(ticket_id)
    end

    def repair(credential, generation:, use_count:)
      remove = generation.status == "revoked" || credential.status == "revoked" ||
        credential.credential_revocation.present?
      before = credential.attendee_index_entry&.removed
      result = Ticketing::AttendeeIndex::Upsert.call(
        credential:, loaded_credential: credential, removed: remove
      )
      require_success!(result)
      after = Ticketing::AttendeeIndexEntry.where(credential_id: credential.id).pick(:removed)
      audit_change(credential, generation:, before:, after:, remove:, use_count:)
      emit(credential, before:, after:, remove:)
    rescue StandardError => error
      instrument_outcome(
        "reconciliation.credential_projection",
        record: credential,
        batch_id:,
        outcome: "error",
        code: error.class.name
      ) { raise }
    end

    def emit(credential, before:, after:, remove:)
      instrument_outcome(
        "reconciliation.credential_projection",
        record: credential,
        batch_id:,
        outcome: before == after ? "unchanged" : "repaired",
        code: remove ? "projection_removed" : "projection_rebuilt"
      ) { now }
    end

    def audit_change(credential, generation:, before:, after:, remove:, use_count:)
      return if before == after

      result = Core::Audit::Record.call(
        audit_key: "reconciliation:credential-projection:#{credential.id}:#{generation.version}:#{remove}",
        action: "reconciliation.credential_projection.repaired",
        auditable_type: credential.class.name,
        auditable_id: credential.id,
        audited_changes: { attendee_index_removed: [ before, after ] },
        metadata: { generation_version: generation.version, admission_use_count: use_count, batch_id: }
      )
      raise result.error if result.failure?
    end
  end
end
