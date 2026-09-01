# frozen_string_literal: true

module Marketplace
  # Authorized marketplace listing boundary. Listing creation/cancellation
  # delegates to one command each; read responses apply the seller/buyer
  # visibility policy without exposing scanner or settlement internals.
  class ResaleListingsController < Marketplace::ApplicationController
    include Core::CommandResponse
    include Core::Pagination

    before_action :ensure_idempotency_key_present, only: %i[create cancel]
    before_action :load_listing, only: %i[show cancel]
    before_action :load_ticket, only: :create

    def index
      @clazz = ResaleListing
      authorize @clazz.new, :index?
      listings = policy_scope(@clazz)
        .where(status: "active")
        .includes(display_includes)
        .order(created_at: :desc)
      render_success(
        data: listings,
        serializer_options: { serializer: Marketplace::Public::ResaleListingSerializer }
      )
    end

    def show
      authorize @listing, :show?
      serializer = seller_or_platform_view? ? ResaleListingSerializer : Marketplace::Public::ResaleListingSerializer
      render_success(data: @listing, serializer_options: { serializer: })
    end

    def create
      authorize @ticket, :create?, policy_class: ResaleListingPolicy
      result = ActivateListing.call(
        ticket: @ticket,
        actor: current_user,
        asking_amount_minor: resale_listing_params.require(:asking_amount_minor),
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: ResaleListingSerializer }
      )
    end

    def cancel
      authorize @listing, :cancel?
      result = CancelListing.call(
        listing: @listing,
        idempotency_key:,
        reason: resale_listing_params[:reason] || "seller_requested"
      )
      render_service_result(result, serializer_options: { serializer: ResaleListingSerializer })
    end

    private

    def load_listing
      @listing = ResaleListing.includes(display_includes).find(params[:id])
    end

    def load_ticket
      @ticket = Ticketing::Ticket.includes(event: :organization).find(params[:ticket_id] || params[:id])
    end

    def resale_listing_params
      params.fetch(:resale_listing, ActionController::Parameters.new).permit(:asking_amount_minor, :reason)
    end

    def display_includes
      [
        :event,
        :commercial_fee_component,
        {
          ticket: {
            event_product: [ :ticket_type, { product_accesses: { event_date: :venue } } ]
          }
        }
      ]
    end

    def seller_or_platform_view?
      @listing.seller_user_id == current_user.id || platform_admin?
    end

    def platform_admin?
      current_user.super_admin? || current_user.has_role?("ADMIN") || current_user.has_role?("CORE_ADMIN")
    end
  end
end
