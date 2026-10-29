# frozen_string_literal: true

module Orders
  # Buyer-owned payment reconciliation. It may verify a pending provider
  # attempt, but ticket issuance remains asynchronous and durable.
  class PaymentRefreshController < Orders::ApplicationController
    before_action :ensure_idempotency_key_present
    before_action :set_payment
    before_action :set_no_store

    def create
      authorize @payment, :refresh?
      result = Orders::PaymentRefresh.call(
        payment: @payment, buyer: current_user, idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: {
          payment: { serializer: Orders::PaymentSerializer },
          order: { serializer: Orders::OrderSerializer },
          tickets: ticket_wallet_serializer_options(result)
        }
      )
    end

    private

    def set_payment
      @payment = Orders::Payment.includes(
        order: [ :event, :order_items, :order_adjustments ]
      ).joins(:order).where(orders_orders: { buyer_user_id: current_user.id }).find(params.require(:payment_id))
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end

    def ticket_wallet_serializer_options(result)
      options = { serializer: Ticketing::TicketWalletSerializer, current_user: }
      return options unless result.success?

      tickets = result.value.fetch(:tickets)
      registrations = Ticketing::Registration.where(
        id: tickets.where.not(registration_id: nil).select(:registration_id)
      ).to_a
      options.merge(
        correction_window_cutoffs: Ticketing::Answers::CorrectionWindow.cutoffs_for(registrations:)
      )
    end
  end
end
