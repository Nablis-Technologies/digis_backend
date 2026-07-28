require "test_helper"

module Catalog
  module Pricing
    class QuoteDebugTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @product = Catalog::Products::Create.new(
          event: @event,
          attributes: { name: "Festival Pass", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic",
            date_selection: "fixed", admissions_per_unit: 1
          }
        ).call.value
      end

      test "debug rounding" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "base", currency: "EUR",
          amount_minor: 1000, active_from: 1.day.ago
        )
        Catalog::ExchangeRate.create!(
          from_currency: "EUR", to_currency: "USD", rate: 1.1234, effective_from: 2.days.ago
        )
        rate_record = Catalog::ExchangeRate.rate_for(from: "EUR", to: "USD", at: Time.current)
        puts "Rate record: #{rate_record.inspect}"
        puts "Rate value: #{rate_record.rate.inspect}"
        puts "Rate class: #{rate_record.rate.class}"
        
        result = Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD", at: Time.current)
        puts "Result: #{result.inspect}"
        if result.success?
          puts "Quote: #{result.value.amount_minor}"
        end
      end
    end
  end
end
