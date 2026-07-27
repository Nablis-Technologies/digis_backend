require_relative "boot"

require "rails/all"

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

    config.x.outbox_handlers = {}

    # Application-level encryption (Active Record Encryption). Keys are sourced
    # from the environment and never committed. In test we fall back to stable
    # keys so the suite boots deterministically without a real master key.
    if ENV["CORE_ENCRYPTION_PRIMARY_KEY"].present?
      config.active_record.encryption.primary_key = ENV["CORE_ENCRYPTION_PRIMARY_KEY"]
      config.active_record.encryption.deterministic_key = ENV["CORE_ENCRYPTION_DETERMINISTIC_KEY"]
      config.active_record.encryption.key_derivation_salt = ENV["CORE_ENCRYPTION_KEY_DERIVATION_SALT"]
    elsif Rails.env.test?
      config.active_record.encryption.primary_key = "test_primary_key_1234567890abcdef1234567890abcdef"
      config.active_record.encryption.deterministic_key = "test_deterministic_key_1234567890abcdef1"
      config.active_record.encryption.key_derivation_salt = "test_key_derivation_salt_1234567890abc"
    end
  end
end
