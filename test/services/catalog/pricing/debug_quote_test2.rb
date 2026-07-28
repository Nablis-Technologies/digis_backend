require "test_helper"

module Catalog
  module Pricing
    class QuoteDebugTest2 < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @product = Catalog::Products::Create.new(
          event: @event,
          attributes: { name: "Debug Pass", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic",
            date_selection: "fixed", admissions_per_unit: 1
          }
        ).call.value
      end

      test "debug rounding v2" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "base", currency: "EUR",
          amount_minor: 1000, active_from: 1.day.ago
        )
        er = Catalog::ExchangeRate.new(
          from_currency: "EUR", to_currency: "USD", rate: 1.1234, effective_from: 2.days.ago
        )
        puts "Before save: rate=#{er.rate.inspect} (#{er.rate.class})"
        puts "  rate.to_d=#{er.rate.to_d.inspect}"
        er.save!
        er.reload
        puts "After reload: rate=#{er.rate.inspect} (#{er.rate.class})"
        
        rate_record = Catalog::ExchangeRate.rate_for(from: "EUR", to: "USD", at: Time.current)
        puts "rate_for: rate=#{rate_record.rate.inspect} (#{rate_record.rate.class})"
      end
    end
  end
end
