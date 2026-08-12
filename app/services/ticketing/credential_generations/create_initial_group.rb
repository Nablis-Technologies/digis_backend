# frozen_string_literal: true

module Ticketing
  module CredentialGenerations
    # Creates the first complete group generation for a package. A package
    # always gets every snapshotted admission slot; only activation is delayed
    # when personal consent or the product's identity requirement is incomplete.
    class CreateInitialGroup < Core::BaseService
      def initialize(ticket:, admission_slots: nil, issuance_context: nil, skip_existing_lookup: false)
        @ticket = ticket
        @admission_slots = admission_slots
        @issuance_context = issuance_context
        @skip_existing_lookup = skip_existing_lookup
      end

      def call
        ticket = load_ticket
        existing = if skip_existing_lookup
          nil
        else
          Ticketing::CredentialGeneration.includes(:credentials).find_by(ticket_id: ticket.id, version: 1)
        end
        return success(existing.credentials.sole) if existing

        generation = ticket.credential_generations.create!(
          version: 1,
          mode: "group",
          status: "active",
          activated_at: Time.current
        )
        ticket.update!(current_credential_generation: generation)
        credential = generation.credentials.create!(
          ticket:,
          event: ticket.event,
          type: "package",
          status: "pending_requirements",
          slot_positions: slot_positions(ticket),
          entry_limit: ticket.admissions_per_unit_snapshot
        )

        return success(credential) unless activatable?(ticket)

        activation = Ticketing::Credentials::Activate.call(
          credential:,
          loaded_credential: credential,
          issuance_context:
        )
        return failure(activation.error) if activation.failure?

        success(activation.value)
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.initial_group_failed"),
            code: "initial_group_failed",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :ticket
      attr_reader :admission_slots, :issuance_context

      def load_ticket
        return ticket if ticket.association(:event).loaded?

        Ticketing::Ticket.includes(
          :event,
          :admission_slots,
          registration: :consent_requirements,
          event_product: [ :ticket_type, { product_accesses: :event_date } ]
        ).lock.find(ticket.id)
      end

      def slot_positions(loaded_ticket)
        (admission_slots || loaded_ticket.admission_slots.to_a).map(&:position).sort
      end

      def skip_existing_lookup
        @skip_existing_lookup
      end

      def activatable?(loaded_ticket)
        return false if identity_name_required?(loaded_ticket)
        return true unless loaded_ticket.registration_id

        !loaded_ticket.registration.consent_requirements.any? do |requirement|
          requirement.required? && requirement.acceptance_scope == "admission_slot" &&
            requirement.package_unit_number == loaded_ticket.unit_number && requirement.pending?
        end
      end

      def identity_name_required?(loaded_ticket)
        loaded_ticket.event_product.ticket_type.entry_validation_mode == "qr_and_id"
      end
    end
  end
end
