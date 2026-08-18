# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    # Keeps seller payout provider selection injectable. Jobs resolve the
    # registered adapter while commands accept an adapter directly in tests
    # and in future provider-specific orchestration.
    class Registry
      class << self
        def register(provider, adapter)
          raise ArgumentError unless adapter.is_a?(Adapter)

          adapters[normalize_provider(provider)] = adapter
        end

        def fetch(provider)
          adapters.fetch(normalize_provider(provider))
        end

        def available = adapters.keys.sort.freeze

        private

        def adapters
          @adapters ||= {}
        end

        def normalize_provider(provider)
          provider.to_s.strip.downcase
        end
      end
    end
  end
end
