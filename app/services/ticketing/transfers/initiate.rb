# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Transfers
    # Opens an append-only package transfer. Pending transfers do not change
    # ownership or credentials; only authenticated recipient acceptance does.
    class Initiate < Core::BaseService
      Result = Data.define(:transfer, :token)

      def initialize(ticket:, actor:, phone:, idempotency_key:, reason: nil, expires_at: nil)
        @ticket = ticket
        @actor = actor
        @phone = phone
        @idempotency_key = idempotency_key
        @reason = reason.to_s.strip.presence
        @expires_at = expires_at
      end

      def call
        key = Core::IdempotencyKey.new(@idempotency_key)
        requested_expiry = parse_expiry
        return failure(error(:transfer_expiry_invalid, :unprocessable_entity)) if @expires_at.present? && requested_expiry.nil?

        outcome = nil
        Ticketing::TicketTransfer.transaction do
          ticket = load_ticket
          validation = validate(ticket)
          if validation
            outcome = failure(validation)
            raise ActiveRecord::Rollback
          end

          pending = ticket.ticket_transfers.lock.find_by(status: "pending")
          if pending && pending.expires_at && pending.expires_at <= Time.current
            pending.update!(status: "expired")
            pending = nil
          end
          if pending
            outcome = failure(error(:transfer_already_pending, :conflict))
            raise ActiveRecord::Rollback
          end

          identity = Core::PhoneIdentity::ResolveOrCreate.call(
            phone: @phone,
            actor: @actor,
            allow_actor_mismatch: true
          )
          if identity.failure?
            outcome = identity
            raise ActiveRecord::Rollback
          end
          if identity.value.user.id == ticket.owner_user_id
            outcome = failure(error(:transfer_recipient_same_as_owner, :unprocessable_entity))
            raise ActiveRecord::Rollback
          end

          token = SecureRandom.urlsafe_base64(32)
          transfer = ticket.ticket_transfers.create!(
            from_user: ticket.owner_user,
            to_user: identity.value.user,
            initiated_by: @actor,
            token_digest: Ticketing::TicketTransfer.token_digest_for(token:),
            status: "pending",
            previous_version: ticket.credential_version,
            reason: @reason,
            expires_at: expiry(ticket, requested_expiry)
          )
          record_audit!(transfer, key)
          publish_outbox!(transfer, key)
          outcome = success(Result.new(transfer:, token:))
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:ticket_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid
        failure(error(:transfer_conflict, :conflict))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:transfer_already_pending, :conflict))
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :unprocessable_entity))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def load_ticket
        Ticketing::Ticket.includes(
          :event,
          :owner_user,
          :revocation,
          :current_credential_generation,
          :ticket_transfers,
          event_product: [ :ticket_type, { product_accesses: :event_date } ]
        ).lock.find(@ticket.id)
      end

      def validate(ticket)
        return error(:transfer_forbidden, :forbidden) unless @actor.is_a?(Core::User) && ticket.owner_user_id == @actor.id
        return error(:package_dead, :conflict) if ticket.package_dead?
        return error(:ticket_suspended, :conflict) if ticket.package_suspended?
        return error(:ticket_not_active, :conflict) unless ticket.status == "active"
        return error(:event_not_active, :conflict) if ticket.event.status.in?(%w[cancelled completed])
        return error(:transfer_not_enabled, :unprocessable_entity) unless ticket.event_product.ticket_type&.transferable?
        return error(:generation_not_current, :conflict) unless current_generation?(ticket)
        return error(:transfer_cutoff_passed, :conflict) if cutoff_passed?(ticket)

        nil
      end

      def current_generation?(ticket)
        generation = ticket.current_credential_generation
        generation&.status == "active" && generation.version == ticket.credential_version &&
          generation.mode == ticket.credential_mode
      end

      def expiry(ticket, requested_expiry)
        requested = requested_expiry || 7.days.from_now
        [ requested, cutoff_at(ticket) ].compact.min
      end

      def parse_expiry
        return @expires_at if @expires_at.is_a?(Time)
        return if @expires_at.blank?

        Time.zone.parse(@expires_at.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def cutoff_at(ticket)
        dates = ticket.event_product.product_accesses.map(&:event_date).compact.reject { |date| date.status == "cancelled" }
        return if dates.empty?

        seconds = ticket.event_product.ticket_type&.transfer_cutoff_seconds_before_start.to_i
        dates.map { |date| date.starts_at - seconds.seconds }.min
      end

      def cutoff_passed?(ticket)
        cutoff = cutoff_at(ticket)
        cutoff.present? && Time.current >= cutoff
      end

      def record_audit!(transfer, key)
        Core::Audit::Record.call(
          audit_key: "ticketing-ticket-transfer-initiated-#{key.digest}",
          action: "ticketing.ticket_transfer.initiated",
          auditable_type: transfer.class.name,
          auditable_id: transfer.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { ticket_id: transfer.ticket_id, to_user_id: transfer.to_user_id },
          metadata: { previous_version: transfer.previous_version, idempotency_key_digest: key.digest }
        )
      end

      def publish_outbox!(transfer, key)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.ticket_transfer.initiated",
          aggregate: transfer,
          payload: { transfer_id: transfer.id, ticket_id: transfer.ticket_id },
          idempotency_key: "ticketing-ticket-transfer-initiated-#{key.digest}"
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
