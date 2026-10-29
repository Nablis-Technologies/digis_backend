# frozen_string_literal: true

module Admin
  module Marketing
    # Platform operators manage versioned offers here; domain commands retain
    # ownership of locking, idempotency, immutable terms, and audit evidence.
    class PlacementOffersController < Admin::ApplicationController
      include Core::Pagination
      include Core::Filterable
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: %i[create activate retire]
      before_action :set_offer, only: %i[show activate retire]

      def index
        offer_class = ::Marketing::PlacementOffer
        authorize offer_class, :index?
        offers = apply_ordering(filter_records(policy_scope(offer_class).order(created_at: :desc, id: :desc)))
        total_count = offers.count if paginated_request?
        offers = paginated_request? ? apply_pagination(offers) : offers.limit(default_per_page)
        render_success(
          data: offers,
          serializer_options: { serializer: ::Admin::Marketing::PlacementOfferSerializer },
          pagination: paginated_request? ? pagination_metadata(total_count) : nil
        )
      end

      def show
        authorize @offer, :show?
        render_success(data: @offer, serializer_options: { serializer: ::Admin::Marketing::PlacementOfferSerializer })
      end

      def create
        authorize ::Marketing::PlacementOffer.new, :create?
        result = ::Marketing::PlacementOffers::Create.call(
          actor: current_user, attributes: offer_params, idempotency_key:, reason: params[:reason]
        )
        render_service_result(
          result, success_status: :created,
          serializer_options: { serializer: ::Admin::Marketing::PlacementOfferSerializer }
        )
      end

      def activate
        authorize @offer, :activate?
        result = ::Marketing::PlacementOffers::Activate.call(
          offer_id: @offer.id, actor: current_user, idempotency_key:, reason: params[:reason]
        )
        render_service_result(result,
          serializer_options: { serializer: ::Admin::Marketing::PlacementOfferSerializer })
      end

      def retire
        authorize @offer, :retire?
        result = ::Marketing::PlacementOffers::Retire.call(
          offer_id: @offer.id, actor: current_user, idempotency_key:, reason: params[:reason]
        )
        render_service_result(result,
          serializer_options: { serializer: ::Admin::Marketing::PlacementOfferSerializer })
      end

      private

      def set_offer
        @offer = ::Marketing::PlacementOffer.find(params[:id])
      end

      def offer_params
        params.require(:placement_offer).permit(
          :code, :surface, :daily_rate_minor, :currency, :minimum_duration_seconds,
          :maximum_duration_seconds, :terms_version, :starts_at, :ends_at
        ).to_h
      end

      def allowed_order_columns
        %w[id code version surface daily_rate_minor currency status starts_at ends_at created_at updated_at]
      end
    end
  end
end
