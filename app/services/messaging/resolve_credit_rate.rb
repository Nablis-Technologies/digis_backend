# frozen_string_literal: true

module Messaging
  # Selects one immutable rate version using the documented specificity order.
  class ResolveCreditRate < Core::BaseService
    def initialize(organization:, channel:, quantity:, currency:, country_code: nil, at: Time.current)
      @organization = organization
      @channel = channel.to_s.strip.downcase
      @quantity = quantity
      @currency = currency.to_s.strip.upcase
      @country_code = country_code.to_s.strip.upcase.presence
      @at = at.to_time
    end

    def call
      return failure(error(:rate_unavailable, :unprocessable_entity)) unless valid_request?

      scope_candidates.each do |scope_name, organization_id, country_code|
        result = select_scope(scope_name, organization_id, country_code)
        return result if result
      end

      failure(error(:rate_unavailable, :unprocessable_entity))
    end

    private

    attr_reader :organization, :channel, :quantity, :currency, :country_code, :at

    def valid_request?
      quantity.is_a?(Integer) && quantity.positive? &&
        channel.in?(CreditAccount::CHANNELS) && currency.match?(/\A[A-Z]{3}\z/) &&
        (country_code.nil? || country_code.match?(/\A[A-Z]{2}\z/))
    end

    # Specificity cascade (most to least specific):
    # 1. Organization + Country (custom rate negotiated for org in specific market)
    # 2. Global + Country (platform rate for specific market)
    # 3. Organization + Default (custom fallback rate for org)
    # 4. Global + Default (platform baseline fallback)
    def scope_candidates
      organization_id = organization&.id
      candidates = []
      candidates << [ "organization_country", organization_id, country_code ] if organization_id && country_code
      candidates << [ "global_country", nil, country_code ] if country_code
      candidates << [ "organization_default", organization_id, nil ] if organization_id
      candidates << [ "global_default", nil, nil ]
      candidates
    end

    def select_scope(scope_name, organization_id, scoped_country)
      # More than one matching version/tier is an unsafe quote, not a reason to
      # guess. Failing closed protects the price digest used by the purchase.
      rates = CreditRateVersion.active_at(at).where(
        organization_id:, channel:, country_code: scoped_country, currency:
      ).order(version: :desc).to_a
      matches = rates.filter_map { |rate| matching_tier(rate) }
      return if matches.empty?
      return failure(error(:rate_unavailable, :unprocessable_entity)) if matches.length > 1

      rate, tier = matches.first
      return failure(error(:rate_unavailable, :unprocessable_entity)) if tier == :ambiguous

      success(
        rate_version: rate,
        unit_price_minor: tier ? tier.fetch("unit_price_minor", rate.unit_price_minor) : rate.unit_price_minor,
        scope: scope_name,
        tier:
      )
    end

    def matching_tier(rate)
      return [ rate, nil ] if rate.volume_tiers.empty?

      tiers = rate.volume_tiers.select do |tier|
        from = tier["from"].to_i
        to = tier["to"]
        quantity >= from && (to.nil? || quantity <= to.to_i) && tier["unit_price_minor"].to_i.positive?
      end
      return if tiers.empty?
      return [ rate, tiers.first ] if tiers.one?

      [ rate, :ambiguous ]
    end

    def error(key, status)
      Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
    end
  end
end
