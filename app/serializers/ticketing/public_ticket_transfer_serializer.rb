# frozen_string_literal: true

module Ticketing
  # Recipient-safe transfer landing projection. It shows enough context to
  # identify the ticket without exposing the transfer token or full contact.
  class PublicTicketTransferSerializer < ActiveModel::Serializer
    attributes :id, :status, :expires_at, :event, :ticket, :recipient

    def event
      event = object.ticket.event
      { id: event.id, slug: event.slug, title: event.title, timezone: event.timezone, currency: event.currency }
    end

    def ticket
      ticket = object.ticket
      { id: ticket.id, status: ticket.status, unit_number: ticket.unit_number, product: product(ticket) }
    end

    def recipient
      {
        phone: masked_phone(object.to_user.phone),
        email_present: object.to_user.email.present?
      }
    end

    private

    def product(ticket)
      product = ticket.event_product
      { id: product.id, name: product.name, type: product.type }
    end

    def masked_phone(phone)
      value = phone.to_s
      return "" if value.blank?

      "#{value.first(4)}#{"*" * [ value.length - 6, 0 ].max}#{value.last(2)}"
    end
  end
end
