# frozen_string_literal: true

module Orders
  # Resolves a buyer-entered event code to its server-owned promotion before a
  # quote is built. A code is never accepted outside its owning event.
  class PromotionContext < Core::BaseService
    Result = Data.define(:promotion, :promotion_code)

    def initialize(event:, raw_code: nil)
      @event = event
      @raw_code = Catalog::PromotionCode.normalize_code(raw_code)
    end

    def call
      return success(Result.new(promotion: nil, promotion_code: nil)) if @raw_code.blank?

      code = Catalog::PromotionCode.includes(:promotion).find_by(
        code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: @raw_code)
      )
      return failure(invalid_code) unless code&.promotion&.event_id == @event.id

      success(Result.new(promotion: code.promotion, promotion_code: code))
    end

    private

    def invalid_code
      Core::BusinessError.new(
        I18n.t("catalog.promotion_quote.errors.invalid_code"),
        code: "invalid_promotion_code",
        status: :unprocessable_entity
      )
    end
  end
end
