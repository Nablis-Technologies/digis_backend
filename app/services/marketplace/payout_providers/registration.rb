# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    # Registers the shared Chapa transfer transport for marketplace dispatch.
    # Chapa's bank-transfer API does not expose destination tokenization, so the
    # adapter fails closed for seller-account registration until that provider
    # capability is available; it must never silently store raw credentials.
    class Registration
      class << self
        def call(env: ENV, registry: Registry)
          return unless enabled?(env)
          return if env["CHAPA_SECRET_KEY"].to_s.strip.blank?

          mode = env.fetch("CHAPA_MODE", "test")
          reject_live_preview!(env:, mode:)
          registry.register("chapa", ChapaAdapter.new(client: transfer_client(env:, mode:, secret_key: env.fetch("CHAPA_SECRET_KEY"))))
        end

        private

        def enabled?(env)
          env["CHAPA_ENABLED"] == "true" && env["CHAPA_PAYOUT_ENABLED"] == "true"
        end

        def reject_live_preview!(env:, mode:)
          return unless env["RENDER_PREVIEW"] == "true" && mode != "test"

          raise "CHAPA_MODE must be test in the Render preview"
        end

        def transfer_client(env:, mode:, secret_key:)
          Finance::PayoutProviders::ChapaTransferClient.new(
            secret_key:,
            mode:,
            api_base_url: env.fetch(
              "CHAPA_API_BASE_URL", Finance::PayoutProviders::ChapaTransferClient::DEFAULT_API_BASE_URL
            )
          )
        end
      end
    end
  end
end
