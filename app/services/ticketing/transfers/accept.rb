# frozen_string_literal: true

module Ticketing
  module Transfers
    # Accepts a pending package transfer under row locks. Ownership changes
    # before replacement so the new group generation and attendee projection
    # are created for the recipient in the same transaction.
    class Accept < Core::BaseService
      def initialize(token:, actor:)
        @token = token
        @actor = actor
      end

      def call
        outcome = nil
        Ticketing::TicketTransfer.transaction do
          transfer = Ticketing::TicketTransfer.lock.find_by(
            token_digest: Ticketing::TicketTransfer.token_digest_for(token: @token)
          )
          unless transfer
            outcome = failure(error(:transfer_invalid, :not_found))
            raise ActiveRecord::Rollback
          end

          transfer.with_lock do
            if transfer.status == "accepted"
              outcome = replay(transfer)
              raise ActiveRecord::Rollback
            end
            validation = validate(transfer)
            if validation
              outcome = failure(validation)
              raise ActiveRecord::Rollback
            end

            ticket = load_ticket(transfer)
            if ticket.package_dead?
              outcome = failure(error(:package_dead, :conflict))
              raise ActiveRecord::Rollback
            end
            if ticket.package_suspended?
              outcome = failure(error(:ticket_suspended, :conflict))
              raise ActiveRecord::Rollback
            end
            if ticket.credential_version != transfer.previous_version
              outcome = failure(error(:transfer_stale, :conflict))
              raise ActiveRecord::Rollback
            end
            if cutoff_passed?(ticket)
              outcome = failure(error(:transfer_cutoff_passed, :conflict))
              raise ActiveRecord::Rollback
            end

            revoke_pending_claims!(ticket)
            ticket.update!(owner_user: @actor)
            replacement = Ticketing::CredentialGenerations::Replace.call(
              ticket:,
              target_mode: "group",
              reason: "ticket_transferred",
              assignments: {},
              idempotency_key: "ticket-transfer-#{transfer.id}-accept"
            )
            unless replacement.success?
              outcome = replacement
              raise ActiveRecord::Rollback
            end

            transfer.update!(
              status: "accepted",
              new_version: replacement.value.version,
              accepted_at: Time.current
            )
            record_audit!(transfer)
            publish_outbox!(transfer)
            outcome = success(transfer.reload)
          end
        end
        outcome
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_workflow.errors.transfer_acceptance_failed"),
            code: "transfer_acceptance_failed",
            status: :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def validate(transfer)
        return error(:transfer_recipient_mismatch, :forbidden) unless @actor.is_a?(Core::User) && transfer.to_user_id == @actor.id
        return error(:transfer_recipient_unverified, :unprocessable_entity) unless @actor.verified_at.present?
        return error(:transfer_expired, :conflict) if transfer.expires_at <= Time.current
        return error(:transfer_not_pending, :conflict) unless transfer.status == "pending"

        nil
      end

      def replay(transfer)
        return failure(error(:transfer_recipient_mismatch, :forbidden)) unless
          @actor.is_a?(Core::User) && transfer.to_user_id == @actor.id

        success(transfer)
      end

      def load_ticket(transfer)
        Ticketing::Ticket.includes(
          :event,
          :owner_user,
          :revocation,
          current_credential_generation: :credentials,
          admission_slots: :assigned_user,
          event_product: [ :ticket_type, { product_accesses: :event_date } ]
        ).lock.find(transfer.ticket_id)
      end

      def revoke_pending_claims!(ticket)
        old_ids = ticket.current_credential_generation.credentials.where(status: "pending_claim").select(:id)
        Ticketing::CredentialClaim.where(credential_id: old_ids, status: "pending").update_all(status: "revoked", updated_at: Time.current)
      end

      def cutoff_passed?(ticket)
        dates = ticket.event_product.product_accesses.map(&:event_date).compact.reject { |date| date.status == "cancelled" }
        return false if dates.empty?

        seconds = ticket.event_product.ticket_type&.transfer_cutoff_seconds_before_start.to_i
        Time.current >= dates.map { |date| date.starts_at - seconds.seconds }.min
      end

      def record_audit!(transfer)
        Core::Audit::Record.call(
          audit_key: "ticketing-ticket-transfer-accepted-#{transfer.id}",
          action: "ticketing.ticket_transfer.accepted",
          auditable_type: transfer.class.name,
          auditable_id: transfer.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { status: "accepted", new_version: transfer.new_version },
          metadata: { ticket_id: transfer.ticket_id, previous_version: transfer.previous_version }
        )
      end

      def publish_outbox!(transfer)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.ticket_transfer.accepted",
          aggregate: transfer,
          payload: { transfer_id: transfer.id, ticket_id: transfer.ticket_id, version: transfer.new_version },
          idempotency_key: "ticketing-ticket-transfer-accepted-#{transfer.id}"
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
