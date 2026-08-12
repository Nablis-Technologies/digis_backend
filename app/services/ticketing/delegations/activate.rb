# frozen_string_literal: true

module Ticketing
  module Delegations
    # Replaces a package group with one credential per admission slot. The
    # commercial owner stays on the ticket; only admission assignment moves.
    class Activate < Core::BaseService
      def initialize(ticket:, actor:, assignments:, idempotency_key:)
        @ticket = ticket
        @actor = actor
        @assignments = assignments
        @idempotency_key = idempotency_key
      end

      def call
        ticket = Ticketing::Ticket.find(@ticket.id)
        return failure(error(:delegation_forbidden, :forbidden)) unless owner?(ticket)

        assignments = normalize_assignments
        return assignments if assignments.failure?

        Ticketing::CredentialGenerations::Replace.call(
          ticket:,
          target_mode: "delegated",
          reason: "delegation_activated",
          assignments: assignments.value,
          idempotency_key: @idempotency_key
        )
      rescue ActiveRecord::RecordNotFound
        failure(error(:ticket_not_found, :not_found))
      rescue ArgumentError
        failure(error(:invalid_generation_assignments, :unprocessable_entity))
      end

      private

      def owner?(ticket)
        @actor.is_a?(Core::User) && ticket.owner_user_id == @actor.id
      end

      def normalize_assignments
        return failure(error(:invalid_generation_assignments, :unprocessable_entity)) unless @assignments.is_a?(Hash)

        normalized = @assignments.each_with_object({}) do |(position, value), result|
          user = resolve_user(value)
          raise ArgumentError if value.present? && user.nil?

          result[Integer(position)] = user
        rescue ArgumentError, TypeError
          return failure(error(:invalid_generation_assignments, :unprocessable_entity))
        end
        success(normalized)
      end

      def resolve_user(value)
        return if value.blank?
        return value if value.is_a?(Core::User)

        identifier = value.is_a?(Hash) ? value[:user_id] || value["user_id"] || value[:id] || value["id"] : value
        Core::User.find_by(id: identifier)
      end

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("ticketing.package_workflow.errors.#{key}"),
          code: key,
          status:
        )
      end
    end
  end
end
