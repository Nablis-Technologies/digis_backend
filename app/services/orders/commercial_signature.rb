# frozen_string_literal: true

require "digest"
require "json"

module Orders
  # Produces the stable provider-context signature for immutable Commercial
  # evidence. Payment-provider code can use it to reject a changed quote
  # without asking the Commercial module to recalculate anything.
  class CommercialSignature
    def self.call(...)
      new(...).call
    end

    class << self
      alias build call
      alias for call
    end

    def initialize(commercial_results:, provider:, payment_method:, charge_currency:)
      @commercial_results = commercial_results.to_a
      @provider = provider.to_s.downcase.presence
      @payment_method = payment_method.to_s.downcase.presence
      @charge_currency = charge_currency.to_s.upcase
    end

    def call
      Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))
    end

    private

    def payload
      {
        provider: @provider,
        payment_method: @payment_method,
        charge_currency: @charge_currency,
        commercial_results: @commercial_results.map(&:overall_signature)
      }
    end

    def canonical(value)
      case value
      when Hash
        value.stringify_keys.sort.to_h { |key, child| [ key, canonical(child) ] }
      when Array
        value.map { |child| canonical(child) }
      else
        value
      end
    end
  end
end
