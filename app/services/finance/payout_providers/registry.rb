# frozen_string_literal: true

module Finance
  module PayoutProviders
    # Keeps provider selection explicit and injectable. Jobs resolve registered
    # adapters, while commands accept an adapter directly for deterministic
    # tests and for future provider-specific orchestration.
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
