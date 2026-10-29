# frozen_string_literal: true

module Payments
  module Providers
    # Registers configured external providers after Rails has finished loading
    # application constants. Disabled providers remain absent from the registry.
    class Registration
      class << self
        def call(env: ENV, registry: Registry)
          return unless env["CHAPA_ENABLED"] == "true"

          mode = env.fetch("CHAPA_MODE", "test")
          preview = env["RENDER_PREVIEW"] == "true"
          raise "CHAPA_MODE must be test in the Render preview" if preview && mode != "test"

          registry.register("chapa", chapa_adapter(env:, mode:))
        end

        private

        def chapa_adapter(env:, mode:)
          ChapaAdapter.new(
            client: ChapaClient.new(
              secret_key: env.fetch("CHAPA_SECRET_KEY"),
              webhook_secret: env.fetch("CHAPA_WEBHOOK_SECRET"),
              mode:,
              callback_url: env["CHAPA_CALLBACK_URL"],
              return_url: env["CHAPA_RETURN_URL"],
              api_base_url: env.fetch("CHAPA_API_BASE_URL", ChapaClient::DEFAULT_API_BASE_URL)
            ),
            capabilities: {
              currencies: %w[ETB USD],
              payment_methods: %w[telebirr cbebirr mpesa awashbirr ebirr enat_bank card bank],
              direct_charge: { supported: true, payment_methods: %w[telebirr cbebirr mpesa awashbirr] },
              cancel: false,
              refunds: { supported: true, partial: true, fee_estimate_minor: 0 }
            }
          )
        end
      end
    end
  end
end
