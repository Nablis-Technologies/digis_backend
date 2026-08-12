# frozen_string_literal: true

module Ticketing
  module Suspensions
    # Opens one reversible review case and sets only the temporary suspension
    # projection. It never changes ticket ownership, payment state, or history.
    class Open < Core::BaseService
      include Support

      def initialize(ticket:, actor:, reason_code:, review_deadline_at: nil, internal_note: nil, idempotency_key:)
        @ticket = ticket
        @actor = actor
        @reason_code = reason_code.to_s.strip.downcase
        @review_deadline_at = review_deadline_at
        @internal_note = internal_note
        @idempotency_key = idempotency_key
      end

      def call
        digest = key_digest
        deadline = parse_deadline(@review_deadline_at)
        return failure(suspension_error(:review_deadline_invalid)) unless deadline
        return failure(suspension_error(:reason_invalid)) unless TicketSuspension::REASON_CODES.include?(@reason_code)
        return failure(suspension_error(:review_deadline_invalid)) unless deadline > Time.current && deadline <= 30.days.from_now

        outcome = nil
        Ticketing::Ticket.transaction do
          ticket, event, revocation = load_context(@ticket.id)
          unless authorized?(@actor, event)
            outcome = failure(suspension_error(:suspension_forbidden, :forbidden))
            next
          end
          unless active_event?(event)
            outcome = failure(suspension_error(:event_not_active, :conflict))
            next
          end
          if ticket.package_dead?
            outcome = failure(suspension_error(:package_dead, :conflict))
            next
          end
          if ticket.status != "active"
            outcome = failure(suspension_error(:ticket_not_active, :conflict))
            next
          end

          existing = Ticketing::TicketSuspension.lock.find_by(idempotency_key: digest)
          if existing
            outcome = replay_or_conflict(existing, ticket)
            next
          end

          active = Ticketing::TicketSuspension.lock.find_by(ticket_id: ticket.id, status: "active")
          if active
            outcome = failure(suspension_error(:suspension_already_active, :conflict))
            next
          end

          suspension = Ticketing::TicketSuspension.create!(
            ticket:,
            event:,
            initiated_by: @actor,
            reason_code: @reason_code,
            internal_note: @internal_note,
            status: "active",
            review_deadline_at: deadline,
            idempotency_key: digest
          )
          publish_projection!(ticket:, event:, revocation:, is_dead: false, is_suspended: true)
          record_transition!(
            suspension:,
            action: "opened",
            actor: @actor,
            metadata: { reason_code: suspension.reason_code, revocation_version: revocation.revocation_version }
          )
          publish_transition!(suspension:, ticket:, revocation:, action: "opened")
          outcome = success(suspension)
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(suspension_error(:ticket_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(suspension_error(:suspension_invalid, errors: error.record.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        failure(suspension_error(:suspension_already_active, :conflict))
      rescue ArgumentError
        failure(suspension_error(:invalid_idempotency_key))
      rescue Core::Error => error
        failure(error)
      end

      private

      def replay_or_conflict(existing, ticket)
        return success(existing) if existing.ticket_id == ticket.id && existing.initiated_by_id == @actor.id &&
          existing.reason_code == @reason_code

        failure(suspension_error(:idempotency_conflict, :conflict))
      end
    end
  end
end
