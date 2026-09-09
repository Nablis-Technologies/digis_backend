# frozen_string_literal: true

module Ticketing
  # Guest-only payment confirmation projection. Claim material is intentionally
  # separate from the authenticated wallet serializer and is never returned by
  # member-facing payment refresh responses.
  class GuestPaymentTicketSerializer < TicketWalletSerializer
    attributes :registration_id, :ticket_view_token, :ticket_view_url, :short_url

    def registration_id
      object.registration_id
    end

    def ticket_view_token
      @ticket_view_token ||= Ticketing::GuestTicketViewToken.issue(ticket: object)
    end

    def ticket_view_url
      Links::BrandedUrl.ticket_view(object, token: ticket_view_token)
    end

    def short_url
      Links::BrandedUrl.ticket(object)
    end
  end
end
