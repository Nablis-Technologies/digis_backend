# frozen_string_literal: true

module Ticketing
  module Suspensions
    # Completes a review case. Free packages may be invalidated in this command;
    # paid packages require the later refund evidence workflow and therefore
    # remain suspended until that workflow owns terminal resolution.
    class Resolve < Core::BaseService
      include Support

      RESOLUTIONS = %w[revoked_free cancelled_refunded expired].freeze

      def initialize(suspension:, actor:, resolution:, resolution_reason:, idempotency_key:)
        @suspension = suspension
        @actor = actor
        @resolution = resolution.to_s.strip.downcase
        @resolution_reason = resolution_reason.to_s.strip.downcase
        @idempotency_key = idempotency_key
      end

      def call
        Core::IdempotencyKey.new(@idempotency_key)
        return failure(suspension_error(:resolution_invalid)) unless RESOLUTIONS.include?(@resolution)
        return failure(suspension_error(:resolution_reason_invalid)) unless
          TicketSuspension::RESOLUTION_REASONS.include?(@resolution_reason)

        outcome = nil
        Ticketing::Ticket.transaction do
          suspension = Ticketing::TicketSuspension.lock.find(@suspension.id)
          ticket, event, revocation = load_context(suspension.ticket_id)
          unless authorized?(@actor, event)
            outcome = failure(suspension_error(:suspension_forbidden, :forbidden))
            next
          end
          if suspension.status == @resolution
            outcome = success(suspension)
            next
          end
          unless suspension.status == "active"
            outcome = failure(suspension_error(:suspension_not_active, :conflict))
            next
          end

          if @resolution == "cancelled_refunded"
            outcome = failure(suspension_error(:refund_evidence_required, :conflict))
            next
          end
          if @resolution == "revoked_free" && !free_package?(ticket)
            outcome = failure(suspension_error(:paid_refund_required, :conflict))
            next
          end

          if @resolution == "revoked_free"
            generation_revocation = Ticketing::Revocations::PublishGeneration.call(
              ticket:,
              through_version: ticket.credential_version,
              reason: "free_ticket_revoked"
            )
            unless generation_revocation.success?
              outcome = generation_revocation
              next
            end
            ticket.update!(status: "void")
            ticket.reload
            revocation = Ticketing::Revocation.lock.find(ticket.revocation.id)
          end

          suspension.update!(
            status: @resolution,
            resolved_by: @actor,
            resolution_reason: @resolution_reason,
            resolved_at: Time.current
          )
          publish_projection!(
            ticket:,
            event:,
            revocation:,
            is_dead: @resolution == "revoked_free",
            is_suspended: @resolution != "revoked_free",
            revoked_through_version: @resolution == "revoked_free" ? ticket.credential_version : nil
          )
          record_transition!(
            suspension:,
            action: @resolution,
            actor: @actor,
            metadata: { resolution_reason: @resolution_reason, revocation_version: revocation.revocation_version }
          )
          publish_transition!(
            suspension:,
            ticket:,
            revocation:,
            action: @resolution,
            automated: @resolution == "expired"
          )
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

      private

      def free_package?(ticket)
        Ticketing::Ticket::FREE_ACQUISITION_TYPES.include?(ticket.current_acquisition_type) &&
          ticket.current_acquisition_product_value_minor.to_i.zero?
      end
    end
  end
end
