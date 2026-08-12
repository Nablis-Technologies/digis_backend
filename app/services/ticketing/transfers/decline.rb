# frozen_string_literal: true

module Ticketing
  module Transfers
    # Declines a pending transfer by its intended recipient without touching
    # the original owner or current credential generation.
    class Decline < Core::BaseService
      def initialize(transfer:, actor:, idempotency_key:)
        @transfer = transfer
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        transfer = Ticketing::TicketTransfer.lock.find(@transfer.id)
        return failure(error(:transfer_recipient_mismatch, :forbidden)) unless @actor.is_a?(Core::User) && transfer.to_user_id == @actor.id
        return success(transfer) if transfer.status == "declined"
        return failure(error(:transfer_not_pending, :conflict)) unless transfer.status == "pending"

        transfer.update!(status: "declined", declined_at: Time.current)
        key = Core::IdempotencyKey.new(@idempotency_key)
        Core::Audit::Record.call(
          audit_key: "ticketing-ticket-transfer-declined-#{key.digest}",
          action: "ticketing.ticket_transfer.declined",
          auditable_type: transfer.class.name,
          auditable_id: transfer.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { status: "declined" },
          metadata: { ticket_id: transfer.ticket_id, idempotency_key_digest: key.digest }
        )
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.ticket_transfer.declined",
          aggregate: transfer,
          payload: { transfer_id: transfer.id, ticket_id: transfer.ticket_id },
          idempotency_key: "ticketing-ticket-transfer-declined-#{transfer.id}"
        )
        success(transfer)
      rescue ActiveRecord::RecordNotFound
        failure(error(:transfer_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid
        failure(error(:transfer_transition_failed, :unprocessable_entity))
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :unprocessable_entity))
      end

      private

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
