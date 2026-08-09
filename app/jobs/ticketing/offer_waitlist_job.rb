# frozen_string_literal: true

module Ticketing
  # Periodically asks the waitlist command to promote one fitting party per
  # ticket type; concurrency and idempotency remain service responsibilities.
  class OfferWaitlistJob < ApplicationJob
    queue_as :default

    def perform(ticket_type_id: nil, selected_event_date_id: nil)
      # A scoped invocation is useful for event-date capacity recovery while the
      # recurring invocation scans every waitlist-enabled ticket type.
      scope = Ticketing::TicketType
        .joins(:event_product)
        .where(waitlist_enabled: true)
      scope = scope.where(id: ticket_type_id) if ticket_type_id.present?

      scope.find_each do |ticket_type|
        Ticketing::Waitlist::OfferNext.call(
          ticket_type:,
          selected_event_date_id:,
          idempotency_key: "ticketing-waitlist-job-#{ticket_type.id}-#{Time.current.to_i / 60}"
        )
      end
    end
  end
end
