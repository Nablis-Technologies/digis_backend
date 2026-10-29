# frozen_string_literal: true

module Ticketing
  # Authenticated owner wallet. The policy scope is the source of ownership;
  # the serializer exposes current credentials only after that boundary.
  class TicketsController < Ticketing::ApplicationController
    include Core::Pagination

    def index
      response.set_header("Cache-Control", "private, no-store")
      @clazz = Ticketing::Ticket
      authorize @clazz.new(owner_user: current_user), :index?

      tickets = policy_scope(@clazz)
        .includes(
          :event,
          :registration,
          :admission_slots,
          :pending_ticket_transfer,
          { current_credential_generation: :credentials },
          { order_item: { order: :order_items } },
          event_product: [ :ticket_type, { product_accesses: { event_date: :venue } } ]
        )
      tickets = apply_ordering(tickets)
      total_count = tickets.count if paginated_request?
      tickets = (paginated_request? ? apply_pagination(tickets) : tickets.limit(default_per_page)).to_a
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      correction_window_cutoffs = Ticketing::Answers::CorrectionWindow.cutoffs_for(
        registrations: tickets.filter_map(&:registration).uniq(&:id)
      )

      render_success(
        data: tickets,
        serializer_options: {
          serializer: Ticketing::TicketWalletSerializer,
          correction_window_cutoffs:
        },
        pagination:
      )
    end

    private

    def allowed_order_columns
      %w[id issued_at created_at status]
    end
  end
end
