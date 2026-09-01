# frozen_string_literal: true

module Ticketing
  # Authenticated owner wallet. The policy scope is the source of ownership;
  # the serializer exposes current credentials only after that boundary.
  class TicketsController < Ticketing::ApplicationController
    include Core::Pagination

    def index
      @clazz = Ticketing::Ticket
      authorize @clazz.new(owner_user: current_user), :index?

      tickets = policy_scope(@clazz)
        .includes(
          :event,
          :admission_slots,
          { current_credential_generation: :credentials },
          event_product: [ :ticket_type, { product_accesses: { event_date: :venue } } ]
        )
      tickets = apply_ordering(tickets)
      total_count = tickets.count if paginated_request?
      tickets = paginated_request? ? apply_pagination(tickets) : tickets.limit(default_per_page)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil

      render_success(
        data: tickets,
        serializer_options: { serializer: Ticketing::TicketWalletSerializer },
        pagination:
      )
    end

    private

    def allowed_order_columns
      %w[id issued_at created_at status]
    end
  end
end
