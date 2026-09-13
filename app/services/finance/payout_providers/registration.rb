# frozen_string_literal: true

module Finance
  module PayoutProviders
    # Registers Chapa V2 payouts only when payout dispatch is explicitly enabled.
    # Preview environments accept test credentials and never live payout keys.
    class Registration
      class << self
        def call(env: ENV, registry: Registry)
          return unless enabled?(env)
          return if env["CHAPA_SECRET_KEY"].to_s.strip.blank?

          mode = env.fetch("CHAPA_MODE", "test")
          reject_live_preview!(env:, mode:)
          registry.register("chapa", chapa_adapter(env:, mode:, secret_key: env.fetch("CHAPA_SECRET_KEY")))
        end

        private

        def enabled?(env)
          env["CHAPA_ENABLED"] == "true" && env["CHAPA_PAYOUT_ENABLED"] == "true"
        end

        def reject_live_preview!(env:, mode:)
          return unless env["RENDER_PREVIEW"] == "true" && mode != "test"

          raise "CHAPA_MODE must be test in the Render preview"
        end

        def chapa_adapter(env:, mode:, secret_key:)
          ChapaAdapter.new(
            client: ChapaPayoutClient.new(
              secret_key:,
              mode:,
              api_base_url: env.fetch("CHAPA_API_BASE_URL", ChapaPayoutClient::DEFAULT_API_BASE_URL)
            ),
            capabilities: {
              currencies: %w[ETB USD],
              amounts: { "ETB" => { minor_unit: 100, fractional: false } },
              payouts: { supported: true },
              balance_api: { supported: false },
              transfer_verification: true
            }
          )
        end
      end
    end
  end
end
