# frozen_string_literal: true

module Ticketing
  module Suspensions
    # Shared transaction primitives for suspension lifecycle commands. Event
    # locking serializes the event-wide revocation version; callers still lock
    # the package first so package ownership and the scanner projection move as
    # one database transaction.
    module Support
      private

      def key_digest
        @key_digest ||= Core::IdempotencyKey.new(@idempotency_key).digest
      end

      def load_context(ticket_id)
        ticket = Ticketing::Ticket.includes(:event, :revocation).lock.find(ticket_id)
        event = Events::Event.lock.find(ticket.event_id)
        revocation = Ticketing::Revocation.lock.find_or_initialize_by(ticket_id: ticket.id)
        revocation.event = event if revocation.new_record?
        [ ticket, event, revocation ]
      end

      def publish_projection!(ticket:, event:, revocation:, is_dead:, is_suspended:, revoked_through_version: nil)
        version = [
          event.revocation_version.to_i,
          Ticketing::Revocation.where(event_id: event.id).maximum(:revocation_version).to_i,
          Ticketing::CredentialRevocation.where(event_id: event.id).maximum(:revocation_version).to_i
        ].max + 1
        revocation.assign_attributes(
          event:,
          is_dead:,
          is_suspended:,
          revoked_through_version: revoked_through_version || revocation.revoked_through_version.to_i,
          revocation_version: version
        )
        revocation.save!
        event.update!(revocation_version: version)
        version
      end

      def record_transition!(suspension:, action:, actor:, metadata: {})
        audit_actor = action == "expired" ? nil : actor
        result = Core::Audit::Record.call(
          audit_key: "ticketing-ticket-suspension-#{suspension.id}-#{action}",
          action: "ticketing.ticket_suspension.#{action}",
          auditable_type: suspension.class.name,
          auditable_id: suspension.id,
          actor_type: audit_actor&.class&.name,
          actor_id: audit_actor&.id,
          audited_changes: { status: action == "opened" ? "active" : suspension.status },
          metadata: metadata.merge(ticket_id: suspension.ticket_id, event_id: suspension.event_id)
        )
        raise result.error if result.failure?
      end

      def publish_transition!(suspension:, ticket:, revocation:, action:, automated: false)
        result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.ticket_suspension.changed",
          aggregate: suspension,
          payload: {
            suspension_id: suspension.id,
            ticket_id: ticket.id,
            event_id: ticket.event_id,
            status: suspension.status,
            revocation_version: revocation.revocation_version,
            package_dead: revocation.is_dead,
            package_suspended: revocation.is_suspended,
            automated:
          },
          idempotency_key: "ticketing-ticket-suspension-#{suspension.id}-#{action}"
        )
        raise result.error if result.failure?
      end

      def suspension_error(key, status = :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.suspensions.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end

      def parse_deadline(value)
        return 7.days.from_now if value.blank?
        return value if value.is_a?(Time)

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def authorized?(actor, event)
        actor.is_a?(Core::User) && Events::AuthorizationResolver.can_manage_catalog?(actor, event)
      end

      def active_event?(event)
        !event.status.in?(%w[cancelled completed])
      end
    end
  end
end
