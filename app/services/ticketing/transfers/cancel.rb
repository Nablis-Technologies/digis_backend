# frozen_string_literal: true

module Ticketing
  module Transfers
    # Cancels a pending transfer by its original owner. No credential
    # generation changes because ownership was never changed while pending.
    class Cancel < Core::BaseService
      def initialize(transfer:, actor:, idempotency_key:)
        @transfer = transfer
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        transition(:cancelled, :cancelled_at, :transfer_cancel_forbidden)
      end

      private

      def transition(status, timestamp, forbidden_code)
        transfer = Ticketing::TicketTransfer.lock.find(@transfer.id)
        return failure(error(forbidden_code, :forbidden)) unless @actor.is_a?(Core::User) && transfer.from_user_id == @actor.id
        return success(transfer) if transfer.status == status
        return failure(error(:transfer_not_pending, :conflict)) unless transfer.status == "pending"

        transfer.update!(status:, timestamp => Time.current)
        record_audit!(transfer, status)
        publish_outbox!(transfer, status)
        success(transfer)
      rescue ActiveRecord::RecordNotFound
        failure(error(:transfer_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid
        failure(error(:transfer_transition_failed, :unprocessable_entity))
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :unprocessable_entity))
      end

      def record_audit!(transfer, status)
        key = Core::IdempotencyKey.new(@idempotency_key)
        Core::Audit::Record.call(
          audit_key: "ticketing-ticket-transfer-#{status}-#{key.digest}",
          action: "ticketing.ticket_transfer.#{status}",
          auditable_type: transfer.class.name,
          auditable_id: transfer.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { status: },
          metadata: { ticket_id: transfer.ticket_id, idempotency_key_digest: key.digest }
        )
      end

      def publish_outbox!(transfer, status)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.ticket_transfer.#{status}",
          aggregate: transfer,
          payload: { transfer_id: transfer.id, ticket_id: transfer.ticket_id },
          idempotency_key: "ticketing-ticket-transfer-#{status}-#{transfer.id}"
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
