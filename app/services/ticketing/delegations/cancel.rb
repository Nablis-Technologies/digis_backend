# frozen_string_literal: true

module Ticketing
  module Delegations
    # Restores one group credential through generation replacement. The prior
    # delegated credentials remain revoked scanner history.
    class Cancel < Core::BaseService
      def initialize(ticket:, actor:, idempotency_key:)
        @ticket = ticket
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        ticket = Ticketing::Ticket.includes(:revocation).find(@ticket.id)
        return failure(error(:delegation_forbidden, :forbidden)) unless owner?(ticket)
        return failure(error(:package_dead, :conflict)) if ticket.package_dead?
        return failure(error(:ticket_suspended, :conflict)) if ticket.package_suspended?
        return failure(error(:delegation_not_active, :conflict)) unless ticket.credential_mode == "delegated"

        Ticketing::CredentialGenerations::Replace.call(
          ticket:,
          target_mode: "group",
          reason: "delegation_cancelled",
          assignments: {},
          idempotency_key: @idempotency_key
        )
      rescue ActiveRecord::RecordNotFound
        failure(error(:ticket_not_found, :not_found))
      end

      private

      def owner?(ticket)
        @actor.is_a?(Core::User) && ticket.owner_user_id == @actor.id
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
