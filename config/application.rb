require_relative "boot"

require "rails/all"
require_relative "../lib/core/outbox/handler_registry"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module DigisBackend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks generators])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
    end

    # DB-level triggers/functions (tamper-evident immutability) cannot be
    # expressed in schema.rb, so dump the full structure as SQL.
    config.active_record.schema_format = :sql

    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Load domain-specific locale files kept below config/locales/*.
    config.i18n.load_path |= Dir[Rails.root.join("config/locales/**/*.yml")]

    # One owner keeps exact and namespace stores isolated while preventing a
    # caller from accidentally registering on a disconnected registry.
    outbox_registry = Core::Outbox::HandlerRegistry.new
    config.x.outbox_handlers = outbox_registry
    config.x.outbox_namespace_handlers = outbox_registry
    config.x.outbox_immediate_dispatch = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch("DIGIS_OUTBOX_IMMEDIATE_DISPATCH", "true")
    )

    # Application-level encryption (Active Record Encryption). Keys are sourced
    # from the environment and never committed. In test we fall back to stable
    # keys so the suite boots deterministically without a real master key.
    if ENV["CORE_ENCRYPTION_PRIMARY_KEY"].present?
      config.active_record.encryption.primary_key = ENV["CORE_ENCRYPTION_PRIMARY_KEY"]
      config.active_record.encryption.deterministic_key = ENV["CORE_ENCRYPTION_DETERMINISTIC_KEY"]
      config.active_record.encryption.key_derivation_salt = ENV["CORE_ENCRYPTION_KEY_DERIVATION_SALT"]
    elsif Rails.env.test? || Rails.env.development?
      # Stable non-production keys so the suite and local dev seed run without a
      # real master key. Never use these in production.
      prefix = Rails.env.test? ? "test" : "dev"
      config.active_record.encryption.primary_key = "#{prefix}_primary_key_1234567890abcdef1234567890abcdef"
      config.active_record.encryption.deterministic_key = "#{prefix}_deterministic_key_1234567890abcdef1"
      config.active_record.encryption.key_derivation_salt = "#{prefix}_key_derivation_salt_1234567890abc"
    end
  end
end
