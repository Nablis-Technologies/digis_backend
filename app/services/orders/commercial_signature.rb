# frozen_string_literal: true

require "digest"
require "json"

module Orders
  # Produces the stable signature for immutable Commercial evidence. Provider
  # and payment-method arguments remain accepted at this boundary because they
  # are inputs to Commercial resolution, but they are deliberately excluded:
  # compatible providers must be able to reuse an identical resolved result.
  class CommercialSignature
    def self.call(...)
      new(...).call
    end

    class << self
      alias build call
      alias for call
    end

    def initialize(commercial_results:, provider: nil, payment_method: nil, charge_currency:)
      @commercial_results = commercial_results.to_a
      @charge_currency = charge_currency.to_s.upcase
    end

    def call
      Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))
    end

    private

    def payload
      {
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
