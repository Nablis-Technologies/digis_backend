# frozen_string_literal: true

require "test_helper"

module Marketplace
  module PayoutProviders
    class DestinationCatalogTest < ActiveSupport::TestCase
      class FakeAdapter < Adapter
        attr_accessor :banks
        attr_reader :requested_country

        def available_banks(country:)
          @requested_country = country
          banks
        end
      end

      test "returns only active bank destinations enabled for ETB in Ethiopia" do
        adapter = FakeAdapter.new
        adapter.banks = [
          bank(slug: "cbe", name: "Commercial Bank of Ethiopia"),
          bank(slug: "telebirr", name: "Telebirr", type: "mobile_money"),
          bank(slug: "closed", active: false),
          bank(slug: "link", type: "store_value"),
          bank(slug: "disabled-currency", enabled: false),
          bank(slug: "missing-market", countries: {})
        ]

        result = DestinationCatalog.call(adapter:, provider: "chapa", country: "ET", currency: "ETB")

        assert_predicate result, :success?
        assert_equal "ET", adapter.requested_country
        assert_equal [
          {
            provider: "chapa", type: "bank", bank_slug: "cbe",
            bank_name: "Commercial Bank of Ethiopia", country: "ET", currency: "ETB"
          },
          {
            provider: "chapa", type: "mobile_money", bank_slug: "telebirr",
            bank_name: "Telebirr", country: "ET", currency: "ETB"
          }
        ], result.value
      end

      test "reports unavailable provider discovery instead of presenting an empty list" do
        adapter = FakeAdapter.new
        adapter.banks = nil

        result = DestinationCatalog.call(adapter:, provider: "chapa", country: "ET", currency: "ETB")

        assert_predicate result, :failure?
        assert_equal "payout_account_provider_unavailable", result.error.code
      end

      test "preserves a valid empty provider list as an empty catalog" do
        adapter = FakeAdapter.new
        adapter.banks = []

        result = DestinationCatalog.call(adapter:, provider: "chapa", country: "ET", currency: "ETB")

        assert_predicate result, :success?
        assert_empty result.value
      end

      private

      def bank(slug:, name: slug, type: "bank", active: true, enabled: true, countries: nil)
        countries ||= { ET: { is_enabled: enabled, min_amount: 10, max_amount: 100_000 } }
        {
          bank_slug: slug, bank_name: name, type:, is_active: active,
          supported_currencies: { ETB: { countries: } }
        }
      end
    end
  end
end
