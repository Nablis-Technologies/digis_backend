# frozen_string_literal: true

module Catalog
  # Organizer API for promotion definitions, lifecycle, and quotes.
  class PromotionsController < Catalog::ApplicationController
    INVALID_AT_ERROR_KEY = :"catalog.promotion_quote.errors.invalid_at"

    before_action :find_promotion, only: %i[show update publish disable quote]
    before_action :ensure_idempotency_key_present, only: %i[create update destroy publish disable]

    def index
      authorize Catalog::Promotion.new, :index?
      promotions = policy_scope(Catalog::Promotion).includes(:promotion_products, :promotion_codes)
      promotions = promotions.where(event_id: params[:event_id]) if params[:event_id].present?
      render_success(data: promotions)
    end

    def show
      authorize @promotion
      render_success(data: @promotion, serializer_options: { include: [ :promotion_codes ] })
    end

    def create
      event = Events::Event.find(params.require(:event_id))
      authorize Catalog::Promotion.new(event: event)

      result = Catalog::Promotions::Create.call(
        event:,
        actor: current_user,
        attributes: promotion_attributes,
        product_ids: params[:product_ids],
        idempotency_key:
      )
      render_command_result(result, status: :created)
    end

    def update
      authorize @promotion
      product_ids = params[:product_ids] if params.key?("product_ids")

      result = Catalog::Promotions::Update.call(
        promotion: @promotion,
        actor: current_user,
        attributes: promotion_attributes,
        product_ids:,
        idempotency_key:
      )
      render_command_result(result)
    end

    def destroy
      promotion = policy_scope(Catalog::Promotion).find_by(id: params[:id])
      authorize promotion if promotion

      result = Catalog::Promotions::DeleteDraft.call(
        promotion: promotion,
        actor: current_user,
        idempotency_key:,
        promotion_id: params[:id]
      )
      render_command_result(result)
    end

    def publish
      authorize @promotion
      result = Catalog::Promotions::PublishVersion.call(
        promotion: @promotion,
        actor: current_user,
        idempotency_key:
      )
      render_command_result(result)
    end

    def disable
      authorize @promotion
      result = Catalog::Promotions::Disable.call(
        promotion: @promotion,
        actor: current_user,
        idempotency_key:
      )
      render_command_result(result)
    end

    def quote
      authorize @promotion
      at = quote_time
      return render_error(INVALID_AT_ERROR_KEY, status: :unprocessable_entity) if at.nil?

      attributes = quote_attributes

      result = Catalog::Promotions::Quote.call(
        promotion: @promotion,
        code: attributes[:code],
        eligible_product_ids: attributes[:eligible_product_ids],
        eligible_subtotal_minor: attributes[:eligible_subtotal_minor],
        charge_currency: attributes[:charge_currency],
        fx_quote: attributes[:fx_quote],
        at:
      )

      if result.success?
        data = Catalog::PromotionQuoteSerializer.new(result.value).attributes.symbolize_keys
        render_success(data: data)
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    private

    def find_promotion
      @promotion = policy_scope(Catalog::Promotion).find(params[:id])
    end

    def promotion_attributes
      params.permit(
        :name, :type, :percentage_basis_points, :fixed_amount_minor, :currency,
        :minimum_subtotal_minor, :maximum_discount_minor, :redemption_limit,
        :per_user_limit, :starts_at, :ends_at, :supersedes_promotion_id,
        product_ids: []
      ).to_h.except("product_ids")
    end

    def quote_attributes
      params.permit(
        :code, :eligible_subtotal_minor, :charge_currency,
        eligible_product_ids: [],
        fx_quote: %i[from_currency charge_currency exchange_rate_id exchange_rate_value]
      ).to_h.deep_symbolize_keys
    end

    def quote_time
      return Time.current if params[:at].blank?

      Time.iso8601(params[:at].to_s)
    rescue ArgumentError
      nil
    end

    def render_command_result(result, status: :ok)
      if result.success?
        render_success(data: result.value, status:)
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end
  end
end
