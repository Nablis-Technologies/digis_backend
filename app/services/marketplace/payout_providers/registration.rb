# frozen_string_literal: true

module Marketplace
  module PayoutProviders
    # Registers the shared Chapa V2 payout transport for marketplace dispatch.
    # Direct payouts require beneficiary fields rather than a destination
    # token, so account registration owns encrypted details and verification.
    class Registration
      class << self
        def call(env: ENV, registry: Registry)
          return unless enabled?(env)
          return if env["CHAPA_SECRET_KEY"].to_s.strip.blank?

          mode = env.fetch("CHAPA_MODE", "test")
          reject_live_preview!(env:, mode:)
          registry.register("chapa", ChapaAdapter.new(client: payout_client(env:, mode:, secret_key: env.fetch("CHAPA_SECRET_KEY"))))
        end

        private

        def enabled?(env)
          env["CHAPA_ENABLED"] == "true" && env["CHAPA_PAYOUT_ENABLED"] == "true"
        end

        def reject_live_preview!(env:, mode:)
          return unless env["RENDER_PREVIEW"] == "true" && mode != "test"

          raise "CHAPA_MODE must be test in the Render preview"
        end

        def payout_client(env:, mode:, secret_key:)
          Finance::PayoutProviders::ChapaPayoutClient.new(
            secret_key:,
            mode:,
            api_base_url: env.fetch(
              "CHAPA_API_BASE_URL", Finance::PayoutProviders::ChapaPayoutClient::DEFAULT_API_BASE_URL
            )
          )
        end
      end
    end
  end
end
