# frozen_string_literal: true

module Reconciliation
  # Claims tickets whose current credential/index projection is inconsistent.
  # Repair is delegated to CredentialProjection so this worker never mutates
  # source credentials or admission history while selecting its batch.
  class CredentialProjectionJob < ApplicationJob
    include Reconciliation::Support

    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    BATCH_SIZE = 100
    MISMATCH_SQL = <<~SQL.squish
      EXISTS (
        SELECT 1
        FROM ticketing_credential_generations generations
        JOIN ticketing_credentials credentials
          ON credentials.credential_generation_id = generations.id
        LEFT JOIN ticketing_attendee_index_entries entries
          ON entries.credential_id = credentials.id
        WHERE generations.id = ticketing_tickets.current_credential_generation_id
          AND (
            (generations.status = 'active' AND credentials.status = 'active' AND
              (entries.id IS NULL OR entries.removed OR
               entries.generation_version <> generations.version OR
               entries.credential_mode <> generations.mode))
            OR ((generations.status = 'revoked' OR credentials.status = 'revoked' OR
                 EXISTS (
                   SELECT 1 FROM ticketing_credential_revocations revocations
                   WHERE revocations.credential_id = credentials.id
                 )) AND entries.id IS NOT NULL AND NOT entries.removed)
          )
      )
    SQL

    def perform(limit = BATCH_SIZE, now: Time.current)
      batch_limit = bounded_limit(limit, BATCH_SIZE)
      batch_id = SecureRandom.uuid
      claim_ticket_ids(batch_limit).each do |ticket_id|
        Reconciliation::CredentialProjection.new(ticket_id:, batch_id:, now:).call
      end
      schedule_remaining(candidate_scope, batch_limit)
    end

    private

    def candidate_scope
      Ticketing::Ticket
        .where(status: %w[active suspended])
        .where.not(current_credential_generation_id: nil)
        .where(MISMATCH_SQL)
    end

    def claim_ticket_ids(limit)
      Ticketing::Ticket.transaction do
        candidate_scope.order(:id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      end
    end
  end
end
