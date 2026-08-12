# frozen_string_literal: true

module Payments
  module Providers
    # Keeps provider selection explicit and injectable. A provider may only
    # reuse an order when its newly resolved Commercial signature matches the
    # immutable order signature; otherwise checkout must be requoted.
    class Registry
      class << self
        def register(provider, adapter)
          raise ArgumentError unless adapter.is_a?(Adapter)

          adapters[normalize_provider(provider)] = adapter
        end

        def fetch(provider)
          adapters.fetch(normalize_provider(provider))
        end

        def available
          adapters.keys.sort.freeze
        end

        def check_commercial_compatibility(expected_signature:, actual_signature:)
          return Core::BaseService::Result.success if expected_signature == actual_signature &&
            valid_signature?(expected_signature)

          Core::BaseService::Result.failure(
            Core::BusinessError.new(
              I18n.t("orders.payments.errors.commercial_requote_required"),
              code: "commercial_requote_required",
              status: :conflict
            )
          )
        end

        private

        def adapters
          @adapters ||= {}
        end

        def normalize_provider(provider)
          provider.to_s.strip.downcase
        end

        def valid_signature?(signature)
          signature.to_s.match?(/\A[0-9a-f]{64}\z/)
        end
      end
    end
  end
end
