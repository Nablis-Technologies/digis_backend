# frozen_string_literal: true

module Ticketing
  module Rsvps
    # Orchestrates a public free RSVP without duplicating registration or
    # inventory rules. Confirmed registrations are issued synchronously when
    # possible; the durable issuance outbox remains the recovery path.
    class Submit < Core::BaseService
      include Ticketing::Registrations::Support

      MAX_PACKAGES = 10
      Result = Data.define(:registration, :tickets, :next_action, :status)

      def initialize(event:, ticket_type:, actor:, submission:, idempotency_key:, phone: nil,
        verification_token: nil, audience_proof: {})
        @event = event
        @ticket_type = ticket_type
        @actor = actor
        @submission = submission
        @raw_idempotency_key = idempotency_key
        @phone = phone
        @verification_token = verification_token
        @audience_proof = audience_proof.to_h.symbolize_keys.slice(:access_code, :invitation)
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        product_error = validate_product
        return failure(product_error) if product_error

        quantity_error = validate_quantity
        return failure(quantity_error) if quantity_error

        guest_identity = resolve_guest_identity if guest_request?
        return guest_identity if guest_identity&.failure?

        registration = nil
        replayed_confirmation = false
        manual_approval = false

        Ticketing::Registration.transaction do
          submitted = unwrap(Ticketing::Registrations::Submit.call(
            ticket_type: locked_ticket_type,
            actor: @actor,
            phone: canonical_phone(guest_identity),
            submission: @submission,
            audience_proof:,
            idempotency_key: key.to_s,
            guest: guest_request?,
            phone_confirmation: guest_request?
          ))

          registration = submitted.registration
          if registration.confirmed?
            replayed_confirmation = true
            next
          end

          if registration.status == "pending_approval"
            manual_approval = true
            next
          end

          unwrap(reserve_capacity!(
            registration,
            idempotency_key: "#{key.digest}:capacity"
          ))

          registration = unwrap(Ticketing::Registrations::ConfirmFree.call(
            registration:,
            actor: @actor || registration.user,
            idempotency_key: "#{key.digest}:confirmation"
          ))
        end

        return success_result(registration, status: :accepted) if manual_approval

        build_automatic_result(registration, replayed_confirmation:)
      rescue Ticketing::Registrations::Support::Halt => error
        return error.result if error.result.error.is_a?(Core::BusinessError)

        failure(rsvp_error("rsvp_registration_failed", errors: { base: [ error.result.error.message ] }))
      rescue ArgumentError => error
        failure(rsvp_error("rsvp_registration_failed", errors: { base: [ error.message ] }))
      rescue ActiveRecord::RecordInvalid => error
        failure(rsvp_error("rsvp_registration_failed", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :event, :ticket_type, :actor, :submission, :phone, :verification_token,
                  :audience_proof

      def guest_request?
        actor.blank?
      end

      def locked_ticket_type
        @locked_ticket_type ||= Ticketing::TicketType
          .includes(event_product: [ :event, :prices, { product_accesses: :event_date } ])
          .lock
          .find(ticket_type.id)
      end

      def validate_product
        classification = ProductEligibility.classify(event:, ticket_type: locked_ticket_type)
        return rsvp_error("rsvp_product_not_found", status: :not_found) if
          classification.in?(%i[not_public not_sellable])
        return rsvp_error("rsvp_paid_product_requires_checkout") if classification == :paid

        nil
      end

      def validate_quantity
        quantity = Integer(submission.package_quantity)
        return if quantity.positive? && quantity <= MAX_PACKAGES

        rsvp_error("rsvp_quantity_invalid")
      rescue ArgumentError, TypeError
        rsvp_error("rsvp_quantity_invalid")
      end

      def resolve_guest_identity
        proof = Core::PhoneVerification::Verify.verify_proof(verification_token)
        return failure(rsvp_error("rsvp_verification_invalid", status: :unprocessable_entity)) unless proof
        return failure(rsvp_error("rsvp_verification_invalid", status: :unprocessable_entity)) unless
          proof[:purpose] == "guest_rsvp"

        challenge = Core::PhoneVerificationChallenge.find_by(
          id: proof[:challenge_id], user_id: proof[:user_id], status: "verified"
        )
        return failure(rsvp_error("rsvp_verification_expired", status: :conflict)) unless challenge
        return failure(rsvp_error("rsvp_verification_expired", status: :conflict)) if challenge.expires_at <= Time.current

        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(phone)
        digest = Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized)
        return failure(rsvp_error("rsvp_verification_invalid", status: :unprocessable_entity)) unless
          normalized.present? && digest == proof[:phone_digest]

        user = Core::User.find_by(id: proof[:user_id])
        return failure(rsvp_error("rsvp_verification_invalid", status: :unprocessable_entity)) unless user

        identity = Core::PhoneIdentity::ResolveOrCreate::Identity.new(user:, digest:)
        return failure(rsvp_error("guest_requires_authentication")) if
          user.password_digest.present? || user.verified_at.present?

        success(identity)
      end

      def canonical_phone(guest_identity)
        return actor.phone if actor

        guest_identity.value.user.phone
      end

      def build_automatic_result(registration, replayed_confirmation:)
        existing = load_wallet_tickets(registration)
        if replayed_confirmation
          return success_result(
            registration,
            tickets: existing,
            next_action: complete_ticket_count?(existing, registration) ? "confirmed" : "issuing",
            status: complete_ticket_count?(existing, registration) ? :ok : :accepted
          )
        end

        Ticketing::Registrations::IssuePackages.call(registration_id: registration.id)
        tickets = load_wallet_tickets(registration)
        return success_result(registration, tickets:, status: :created) if
          complete_ticket_count?(tickets, registration)

        success_result(registration, tickets:, next_action: "issuing", status: :accepted)
      end

      def success_result(registration, tickets: Ticketing::Ticket.none, next_action: nil, status: :accepted)
        next_action ||= registration.status == "pending_approval" ? "awaiting_approval" : "confirmed"
        success(Result.new(registration:, tickets:, next_action:, status:))
      end

      def load_wallet_tickets(registration)
        Ticketing::Ticket.where(registration_id: registration.id)
          .includes(
            :event,
            :admission_slots,
            { current_credential_generation: :credentials },
            { order_item: { order: :order_items } },
            event_product: [ :ticket_type, { product_accesses: { event_date: :venue } } ]
          )
          .order(:unit_number)
      end

      def complete_ticket_count?(tickets, registration)
        tickets.count == registration.package_quantity
      end

      def rsvp_error(code, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.rsvps.errors.#{code}"), code:, status:, errors:
        )
      end
    end
  end
end
