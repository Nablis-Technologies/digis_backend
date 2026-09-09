# frozen_string_literal: true

module Ticketing
  module Rsvps
    # Starts the guest RSVP phone-proof flow only for a public, active, free
    # ticket product. Existing accounts are directed to authenticated RSVP
    # instead of receiving an unnecessary guest OTP.
    class RequestOtp < Core::BaseService
      Result = Data.define(:challenge)

      def initialize(event:, ticket_type:, phone:, idempotency_key:)
        @event = event
        @ticket_type = ticket_type
        @phone = phone
        @idempotency_key = idempotency_key
      end

      def call
        product_error = validate_product
        return failure(product_error) if product_error

        identity = Core::PhoneIdentity::ResolveOrCreate.call(
          phone: @phone, actor: nil, allow_actor_mismatch: true
        )
        return identity if identity.failure?

        user = identity.value.user
        return failure(rsvp_error("guest_requires_authentication")) if
          user.password_digest.present? || user.verified_at.present?

        challenge = Core::PhoneVerification::Request.call(
          user:, phone: @phone, purpose: "guest_rsvp", idempotency_key: @idempotency_key
        )
        return challenge if challenge.failure?

        success(Result.new(challenge: challenge.value))
      end

      private

      attr_reader :event, :ticket_type, :phone, :idempotency_key

      def validate_product
        current_ticket_type = loaded_ticket_type
        classification = ProductEligibility.classify(event:, ticket_type: current_ticket_type)
        return rsvp_error("rsvp_product_not_found", status: :not_found) if
          classification.in?(%i[not_public not_sellable])
        return rsvp_error("rsvp_paid_product_requires_checkout") if classification == :paid

        nil
      end

      def loaded_ticket_type
        @loaded_ticket_type ||= Ticketing::TicketType
          .includes(event_product: [ :event, :prices, { product_accesses: { event_date: :venue } } ])
          .find(ticket_type.id)
      end


      def rsvp_error(code, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.rsvps.errors.#{code}"), code:, status:, errors:
        )
      end
    end
  end
end
