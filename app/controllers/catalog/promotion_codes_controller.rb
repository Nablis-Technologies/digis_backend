# frozen_string_literal: true

module Catalog
  # Organizer API for safe promotion-code metadata and explicit reveals.
  class PromotionCodesController < Catalog::ApplicationController
    before_action :ensure_idempotency_key_present, only: %i[create reveal]
    before_action :find_code, only: %i[show reveal]

    def index
      authorize Catalog::PromotionCode.new, :index?
      codes = policy_scope(Catalog::PromotionCode)
      codes = codes.where(promotion_id: params[:promotion_id]) if params[:promotion_id].present?
      render_success(data: codes)
    end

    def show
      authorize @promotion_code
      render_success(data: @promotion_code, serializer_options: { serializer: Catalog::PromotionCodeSerializer })
    end

    def create
      promotion = policy_scope(Catalog::Promotion).find(params.require(:promotion_id))
      authorize Catalog::PromotionCode.new(promotion: promotion)

      result = Catalog::Promotions::CreateCode.call(
        promotion: promotion,
        actor: current_user,
        attributes: code_attributes,
        idempotency_key:
      )
      if result.success?
        code = result.value
        data = Catalog::PromotionCodeSerializer.new(code.record).attributes.merge(code: code.plaintext)
        render_success(data: data, status: :created)
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    def reveal
      authorize @promotion_code, :reveal?
      result = Catalog::Promotions::RevealCode.call(
        promotion_code: @promotion_code,
        actor: current_user,
        idempotency_key:
      )
      if result.success?
        render_success(data: { id: @promotion_code.id, promotion_id: @promotion_code.promotion_id, code: result.value })
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    private

    def find_code
      @promotion_code = policy_scope(Catalog::PromotionCode).find(params[:id])
    end

    def code_attributes
      params.permit(:code, :label, :redemption_limit, :starts_at, :ends_at, :active).to_h
    end
  end
end
