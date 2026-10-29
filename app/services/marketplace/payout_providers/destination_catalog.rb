# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    # One seller-safe view of destinations accepted by the provider and mapped
    # by the Marketplace payout dispatcher.
    class DestinationCatalog < Core::BaseService
      def initialize(adapter:, provider:, country:, currency:)
        @adapter = adapter
        @provider = provider.to_s.strip.downcase
        @country = country.to_s.strip.upcase
        @currency = currency.to_s.strip.upcase
      end

      def call
        banks = provider_banks
        return failure(provider_unavailable_error) unless banks.is_a?(Array)

        success(banks.filter_map { |bank| normalize(bank) }.uniq { |bank| bank[:bank_slug] }.freeze)
      end

      private

      attr_reader :adapter, :provider, :country, :currency

      def provider_banks
        adapter.available_banks(country:)
      rescue StandardError
        nil
      end

      def normalize(bank)
        return unless bank.is_a?(Hash)

        attributes = bank.deep_symbolize_keys
        slug = attributes[:bank_slug].to_s.strip.downcase
        type = attributes[:type].to_s.strip.downcase
        return unless attributes[:is_active] == true
        return unless SellerPayoutAccount::PROVIDERS.include?(provider)
        return unless SellerPayoutAccount::TYPES.include?(type)
        return unless slug.match?(/\A[a-z0-9][a-z0-9_-]*\z/)
        return unless enabled_for_market?(attributes)

        {
          provider:, type:, bank_slug: slug,
          bank_name: attributes[:bank_name].to_s.strip.presence || slug,
          country:, currency:
        }.freeze
      end

      def enabled_for_market?(attributes)
        supported_currencies = attributes[:supported_currencies].to_h.deep_symbolize_keys
        currency_rules = supported_currencies[currency.to_sym].to_h
        country_rules = currency_rules.fetch(:countries, {}).to_h.deep_symbolize_keys[country.to_sym].to_h
        country_rules[:is_enabled] == true
      end

      def provider_unavailable_error
        Core::BusinessError.new(
          I18n.t("marketplace.resale.errors.payout_account_provider_unavailable"),
          code: "payout_account_provider_unavailable", status: :service_unavailable
        )
      end
    end
  end
end
