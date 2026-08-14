# frozen_string_literal: true

module Marketplace
  # Calculates one immutable resale price cap without persisting policy or
  # applying Commercial fees. Percentage caps use half-up rounding so the
  # resulting integer minor-unit amount is deterministic at checkout.
  class CalculatePriceCap < Core::BaseService
    Result = Data.define(:cap_type, :calculated_cap_minor, :fixed_cap_minor, :percentage_cap_bps)

    def initialize(cap_type:, acquisition_product_value_minor:, fixed_cap_minor: nil, percentage_cap_bps: nil)
      @cap_type = cap_type.to_s.downcase
      @acquisition_product_value_minor = integer_or_nil(acquisition_product_value_minor)
      @fixed_cap_minor = integer_or_nil(fixed_cap_minor)
      @percentage_cap_bps = integer_or_nil(percentage_cap_bps)
    end

    def call
      case @cap_type
      when "fixed"
        fixed_result
      when "percentage"
        percentage_result
      else
        failure_for("resale_cap_type_invalid")
      end
    end

    private

    def fixed_result
      return failure_for("resale_cap_shape_invalid") unless @fixed_cap_minor&.positive? && @percentage_cap_bps.nil?

      success(Result.new(
        cap_type: @cap_type,
        calculated_cap_minor: @fixed_cap_minor,
        fixed_cap_minor: @fixed_cap_minor,
        percentage_cap_bps: nil
      ))
    end

    def percentage_result
      return failure_for("resale_cap_shape_invalid") unless
        @percentage_cap_bps&.positive? && @percentage_cap_bps <= Ticketing::TicketType::RESALE_MAX_PERCENTAGE_BPS &&
        @fixed_cap_minor.nil?
      return failure_for("resale_acquisition_value_required") unless @acquisition_product_value_minor&.positive?

      calculated_cap_minor = (
        BigDecimal(@acquisition_product_value_minor.to_s) * @percentage_cap_bps /
          Ticketing::TicketType::RESALE_MAX_PERCENTAGE_BPS
      ).round(0, BigDecimal::ROUND_HALF_UP).to_i

      success(Result.new(
        cap_type: @cap_type,
        calculated_cap_minor: calculated_cap_minor,
        fixed_cap_minor: nil,
        percentage_cap_bps: @percentage_cap_bps
      ))
    end

    def integer_or_nil(value)
      Integer(value) unless value.nil?
    rescue ArgumentError, TypeError
      nil
    end

    def failure_for(code)
      failure Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"),
        code:,
        status: :unprocessable_entity
      )
    end
  end
end
