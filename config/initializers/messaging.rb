# frozen_string_literal: true

# Registers the durable in-app channel after Rails has prepared autoloaded
# Messaging classes. Email and SMS providers are registered by explicit
# provider configuration later; missing adapters remain observable.
Rails.application.config.after_initialize do
  # Use the registry created by an earlier provider initializer when one
  # exists; assigning a fresh registry here would silently drop that adapter.
  registry = Messaging::Providers::Registry.configure(
    Rails.application.config.x.messaging_provider_registry
  )
  Rails.application.config.x.messaging_provider_registry = Messaging::Providers::PreviewConfiguration.call(
    env: ENV, registry:
  )
end
