# frozen_string_literal: true

# Registers only explicitly enabled providers. Preview defaults remain inert
# until the operator supplies Chapa test credentials through Render secrets.
if ENV["CHAPA_ENABLED"] == "true"
  chapa_mode = ENV.fetch("CHAPA_MODE", "test")
  preview = ENV["RENDER_PREVIEW"] == "true"
  raise "CHAPA_MODE must be test in the Render preview" if preview && chapa_mode != "test"

  chapa_client = Payments::Providers::ChapaClient.new(
    secret_key: ENV.fetch("CHAPA_SECRET_KEY"),
    webhook_secret: ENV.fetch("CHAPA_WEBHOOK_SECRET"),
    mode: chapa_mode,
    api_base_url: ENV.fetch("CHAPA_API_BASE_URL", Payments::Providers::ChapaClient::DEFAULT_API_BASE_URL),
    callback_url: ENV["CHAPA_CALLBACK_URL"],
    return_url: ENV["CHAPA_RETURN_URL"]
  )

  Payments::Providers::Registry.register(
    "chapa",
    Payments::Providers::ChapaAdapter.new(
      client: chapa_client,
      capabilities: {
        currencies: %w[ETB USD],
        payment_methods: %w[telebirr card bank],
        cancel: false,
        refunds: { supported: true, partial: true, fee_estimate_minor: 0 }
      }
    )
  )
end
