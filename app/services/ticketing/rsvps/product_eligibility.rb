# frozen_string_literal: true

module Ticketing
  module Rsvps
    # Classifies a ticket product once so OTP and submission enforce the same
    # public, sellable, free-product boundary.
    module ProductEligibility
      module_function

      def classify(event:, ticket_type:, at: Time.current)
        product = ticket_type.event_product
        return :not_public unless public_ticket?(event:, ticket_type:, product:)

        prices = product.prices.active_at(at)
        return :not_sellable unless prices.exists?

        prices.where.not(amount_minor: 0).none? ? :free : :paid
      end

      def public_ticket?(event:, ticket_type:, product: ticket_type.event_product)
        event.status == "published" && event.visibility == "public" &&
          product.event_id == event.id && product.status == "active" &&
          product.ticket? && ticket_type.audience == "public"
      end
    end
  end
end
