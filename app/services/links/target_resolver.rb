# frozen_string_literal: true

module Links
  # Maps stable link target types to normal application routes without ever
  # constantizing database input. Target existence is checked on resolution.
  class TargetResolver
    TARGETS = {
      "event" => ->(id) { Events::Event.find(id); Rails.application.routes.url_helpers.event_path(id) },
      "ticket" => ->(id) { public_ticket_location(id) },
      "organization" => ->(id) { Organizations::Organization.find(id); Rails.application.routes.url_helpers.organization_path(id) },
      "ticket_transfer" => ->(id) { public_transfer_location(id) }
    }.freeze

    def self.call(target_type, target_id)
      TARGETS.fetch(target_type.to_s).call(target_id)
    rescue KeyError, ActiveRecord::RecordNotFound, ArgumentError
      raise Core::Error, I18n.t("links.errors.target_not_found")
    end

    def self.public_ticket_location(id)
      ticket = Ticketing::Ticket.includes(
        :event,
        event_product: { product_accesses: { event_date: :venue } }
      ).find(id)
      token = Ticketing::GuestTicketViewToken.issue(ticket:)
      "/public/tickets/#{ticket.id}?view_token=#{ERB::Util.url_encode(token)}"
    end

    def self.public_transfer_location(id)
      transfer = Ticketing::TicketTransfer.find(id)
      token = transfer.token
      raise Core::Error, I18n.t("links.errors.target_not_found") if token.blank?

      "/public/ticket_transfers/#{transfer.id}?token=#{ERB::Util.url_encode(token)}"
    end

    private_class_method :public_ticket_location, :public_transfer_location
  end
end
