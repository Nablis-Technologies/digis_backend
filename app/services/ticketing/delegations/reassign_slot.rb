# frozen_string_literal: true

module Ticketing
  module Delegations
    # Reassigns exactly one delegated slot while preserving every other slot.
    # Consent lineage is superseded in the same outer transaction when a
    # registration-backed ticket has a personal requirement for that slot.
    class ReassignSlot < Core::BaseService
      def initialize(ticket:, actor:, position:, replacement_user:, idempotency_key:)
        @ticket = ticket
        @actor = actor
        @position = position
        @replacement_user = replacement_user
        @idempotency_key = idempotency_key
      end

      def call
        outcome = nil
        Ticketing::Ticket.transaction do
          ticket = Ticketing::Ticket.includes(
            :owner_user,
            current_credential_generation: { credentials: [ :admission_slot, :holder_user ] }
          ).lock.find(@ticket.id)
          unless owner?(ticket)
            outcome = failure(error(:delegation_forbidden, :forbidden))
            raise ActiveRecord::Rollback
          end
          unless ticket.credential_mode == "delegated"
            outcome = failure(error(:delegation_not_active, :conflict))
            raise ActiveRecord::Rollback
          end

          position = Integer(@position)
          assignments = current_assignments(ticket)
          unless assignments.key?(position)
            outcome = failure(error(:invalid_delegation_slot, :unprocessable_entity))
            raise ActiveRecord::Rollback
          end
          replacement = resolve_user(@replacement_user)
          if @replacement_user.present? && replacement.nil?
            outcome = failure(error(:invalid_generation_assignments, :unprocessable_entity))
            raise ActiveRecord::Rollback
          end
          assignments[position] = replacement

          consent_reassignment = supersede_consent_if_needed(ticket, position, replacement)
          if consent_reassignment&.failure?
            outcome = consent_reassignment
            raise ActiveRecord::Rollback
          end

          replacement = Ticketing::CredentialGenerations::Replace.call(
            ticket:,
            target_mode: "delegated",
            reason: "delegation_slot_reassigned",
            assignments:,
            idempotency_key: @idempotency_key
          )
          unless replacement.success?
            outcome = replacement
            raise ActiveRecord::Rollback
          end

          outcome = replacement
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:ticket_not_found, :not_found))
      rescue ArgumentError
        failure(error(:invalid_delegation_slot, :unprocessable_entity))
      end

      private

      def owner?(ticket)
        @actor.is_a?(Core::User) && ticket.owner_user_id == @actor.id
      end

      def current_assignments(ticket)
        ticket.current_credential_generation.credentials.each_with_object({}) do |credential, assignments|
          assignments[credential.admission_slot.position] = credential.holder_user
        end
      end

      def resolve_user(value)
        return if value.blank?
        return value if value.is_a?(Core::User)

        if value.is_a?(Hash)
          return Core::User.find_by(id: value[:user_id] || value["user_id"] || value[:id] || value["id"]) if
            value[:user_id] || value["user_id"] || value[:id] || value["id"]

          return Core::PhoneIdentity::ResolveOrCreate.call(
            phone: value[:phone] || value["phone"],
            actor: @actor,
            allow_actor_mismatch: true
          ).value&.user
        end

        Core::User.find_by(id: value)
      end

      def supersede_consent_if_needed(ticket, position, replacement)
        return unless ticket.registration_id

        requirement_exists = Ticketing::RegistrationConsentRequirement.current.where(
          registration_id: ticket.registration_id,
          acceptance_scope: "admission_slot",
          package_unit_number: ticket.unit_number,
          admission_position: position
        ).exists?
        return unless requirement_exists

        Ticketing::Consent::SupersedeForReassignment.call(
          registration: Ticketing::Registration.find(ticket.registration_id),
          package_unit_number: ticket.unit_number,
          admission_position: position,
          actor: @actor,
          replacement_subject: replacement,
          idempotency_key: "#{@idempotency_key}:consent"
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("ticketing.package_workflow.errors.#{key}"), code: key, status:)
      end
    end
  end
end
