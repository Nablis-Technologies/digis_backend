# frozen_string_literal: true

# Inbound adapters are registered explicitly by provider configuration. The
# registry itself is always present so a missing provider remains observable.
Rails.application.config.after_initialize do
  Rails.application.config.x.messaging_inbound_registry = Messaging::Providers::InboundRegistry.configure(
    Rails.application.config.x.messaging_inbound_registry
  )
end
