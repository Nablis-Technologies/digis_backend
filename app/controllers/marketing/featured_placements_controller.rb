# frozen_string_literal: true

module Marketing
  class FeaturedPlacementsController < Marketing::ApplicationController
    include Core::Pagination
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: %i[create cancel]
    before_action :set_event
    before_action :set_placement, only: %i[show cancel]

    def offers
      authorize @event, :manage?, policy_class: FeaturedPlacementPolicy
      result = FeaturedPlacements::EventEligibility.call(event: @event)
      enabled = Rails.application.config.x.marketing_featured_placements_enabled == true
      configured = enabled && FeaturedPlacements::Capacity.limit_for("public_discovery").present?
      offers = result.success? && configured ? PlacementOffer.active_at(Time.current).order(:code, :version) : []
      render_success(data: {
        offers: offers.map { |offer| offer_payload(offer) },
        eligibility: {
          eligible: result.success? && configured,
          reason: result.failure? ? result.error.code : feature_unavailable_reason(enabled, configured),
          doors_at: result.success? ? result.value : nil
        }
      })
    end

    def quote
      authorize @event, :manage?, policy_class: FeaturedPlacementPolicy
      attributes = quote_params
      result = FeaturedPlacements::Quote.call(event: @event, offer: attributes[:offer_id], starts_at: attributes[:starts_at])
      return render_business_error(result.error) if result.failure?

      render_success(data: quote_payload(result.value))
    end

    def index
      authorize @event, :manage?, policy_class: FeaturedPlacementPolicy
      scope = FeaturedPlacement.where(event_id: @event.id, organization_id: @event.organization_id)
        .order(created_at: :desc, id: :desc)
      total_count = scope.count
      placements = apply_pagination(scope).to_a
      financials = placement_financials(placements)
      render_success(
        data: placements.map { |placement| placement_payload(placement, financials: financials.fetch(placement.id)) },
        pagination: pagination_metadata(total_count)
      )
    end

    def show
      authorize @placement, :show?, policy_class: FeaturedPlacementPolicy
      render_success(data: placement_payload(@placement))
    end

    def create
      authorize @event, :create?, policy_class: FeaturedPlacementPolicy
      attributes = quote_params
      result = FeaturedPlacements::Create.call(
        event: @event, purchaser: current_user, offer_id: attributes[:offer_id],
        starts_at: attributes[:starts_at], idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      data = result.value
      render_success(
        data: {
          placement: placement_payload(data.placement, financials: creation_financials(data)),
          payment: payment_payload(data.payment),
          replayed: data.replayed
        },
        status: :created
      )
    end

    def cancel
      authorize @placement, :cancel?, policy_class: FeaturedPlacementPolicy
      result = FeaturedPlacements::Cancel.call(placement: @placement, actor: current_user, idempotency_key:)
      return render_business_error(result.error) if result.failure?

      render_success(data: placement_payload(result.value.placement))
    end

    private

    def set_event
      @event = Events::Event.includes(:organization).find(params[:event_id])
    end

    def set_placement
      @placement = FeaturedPlacement.where(
        event_id: @event.id, organization_id: @event.organization_id
      ).find(params[:id])
    end

    def quote_params
      params.require(:featured_placement).permit(:offer_id, :starts_at)
    end

    def offer_payload(offer)
      offer.slice(
        :id, :code, :version, :daily_rate_minor, :currency, :minimum_duration_seconds,
        :maximum_duration_seconds, :surface, :terms_version, :starts_at, :ends_at
      )
    end

    def quote_payload(quote)
      quote.to_h.slice(
        :offer_id, :offer_code, :offer_version, :surface, :starts_at, :ends_at,
        :duration_seconds, :daily_rate_minor, :amount_minor, :currency, :terms_version,
        :capacity_available, :capacity_limit, :next_available_at
      )
    end

    def feature_unavailable_reason(enabled, configured)
      return "feature_disabled" unless enabled
      return "capacity_unavailable" unless configured

      nil
    end

    def placement_payload(placement, financials: nil)
      financials ||= placement_financials([ placement ]).fetch(placement.id)
      fields = FeaturedPlacementPolicy.new(current_user, placement)
        .visible_attributes_for(record: placement, action: action_name)
      serialize(placement, serializer: FeaturedPlacementSerializer, visible_attributes: fields)
        .deep_symbolize_keys
        .merge(
          payment: payment_payload(financials.fetch(:payment)),
          refund: financials.fetch(:refund)&.slice(:id, :amount_minor, :currency, :status, :reason_code)
        )
    end

    def creation_financials(data)
      {
        purchase: data.billing_purchase,
        payment: data.payment,
        refund: refund_for(data.placement)
      }
    end

    def refund_for(placement)
      return unless placement.refund_id

      Orders::Refund.find_by(id: placement.refund_id)
    end

    def placement_financials(placements)
      purchase_by_source = Orders::BillingPurchase.where(
        source_type: "Marketing::FeaturedPlacement", source_id: placements.map(&:id)
      ).index_by(&:source_id)
      purchases = purchase_by_source.values
      payments_by_purchase = Orders::Payment.where(billing_purchase_id: purchases.map(&:id))
        .order(:attempt_number).to_a.group_by(&:billing_purchase_id)
      refunds = Orders::Refund.where(id: placements.filter_map(&:refund_id)).index_by(&:id)
      placements.to_h do |placement|
        purchase = purchase_by_source[placement.id]
        [
          placement.id,
          {
            purchase:,
            payment: payments_by_purchase[purchase&.id]&.last,
            refund: refunds[placement.refund_id]
          }
        ]
      end
    end

    def payment_payload(payment)
      return unless payment

      payment.slice(:id, :status, :checkout_url, :amount_minor, :currency)
    end
  end
end
