# frozen_string_literal: true

module Marketplace
  # Buyer checkout boundary for one active listing. ReserveListing owns the
  # seller suspension, buyer registration, commercial snapshot, and hold;
  # this controller only authorizes and forwards the request.
  class ResalePurchasesController < Marketplace::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_listing

    def create
      authorize @listing, :purchase?, policy_class: ResaleListingPolicy
      result = ReserveListing.call(
        listing: @listing,
        buyer: current_user,
        idempotency_key:,
        answers: purchase_params[:answers] || [],
        consents: purchase_params[:consents] || []
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::OrderSerializer }
      )
    end

    private

    def load_listing
      @listing = ResaleListing.includes(commercial_fee_component: :fee_schedule_version).find(params[:resale_listing_id])
    end

    def purchase_params
      params.fetch(:purchase, ActionController::Parameters.new).permit(
        answers: {}, consents: {}
      )
    end
  end
end
