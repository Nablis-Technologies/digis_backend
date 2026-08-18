# frozen_string_literal: true

module Ticketing
  module Suspensions
    # Restores a live review case only while the package remains independently
    # admissible. A refund, chargeback, event cancellation, or terminal package
    # revocation always wins over a later review decision.
    class Restore < Core::BaseService
      include Support

      def initialize(suspension:, actor:, resolution_reason:, idempotency_key:)
        @suspension = suspension
        @actor = actor
        @resolution_reason = resolution_reason.to_s.strip.downcase
        @idempotency_key = idempotency_key
      end

      def call
        Core::IdempotencyKey.new(@idempotency_key)
        return failure(suspension_error(:resolution_reason_invalid)) unless @resolution_reason == "review_cleared"

        outcome = nil
        Ticketing::Ticket.transaction do
          suspension = Ticketing::TicketSuspension.lock.find(@suspension.id)
          ticket, event, revocation = load_context(suspension.ticket_id)
          unless authorized?(@actor, event)
            outcome = failure(suspension_error(:suspension_forbidden, :forbidden))
            next
          end
          if suspension.status == "restored"
            outcome = success(suspension)
            next
          end
          unless suspension.status == "active"
            outcome = failure(suspension_error(:suspension_not_active, :conflict))
            next
          end
          if ticket.package_dead? || !active_event?(event)
            outcome = failure(suspension_error(:suspension_not_restorable, :conflict))
            next
          end

          suspension.update!(
            status: "restored",
            resolved_by: @actor,
            resolution_reason: @resolution_reason,
            resolved_at: Time.current
          )
          publish_projection!(ticket:, event:, revocation:, is_dead: false, is_suspended: false)
          record_transition!(
            suspension:,
            action: "restored",
            actor: @actor,
            metadata: { resolution_reason: @resolution_reason, revocation_version: revocation.revocation_version }
          )
          publish_transition!(suspension:, ticket:, revocation:, action: "restored")
          outcome = success(suspension)
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(suspension_error(:suspension_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid
        failure(suspension_error(:suspension_invalid))
      rescue ArgumentError
        failure(suspension_error(:invalid_idempotency_key))
      rescue Core::Error => error
        failure(error)
      end
    end
  end
end
