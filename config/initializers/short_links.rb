# frozen_string_literal: true

# Branded links are opt-in. The application remains fully usable through its
# normal routes when the feature or short-link host is not configured.
config = ActiveSupport::OrderedOptions.new
config.enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SHORT_LINKS_ENABLED", "false"))
config.host = ENV.fetch("SHORT_LINKS_HOST", "dig.is").to_s.strip
config.protocol = ENV.fetch(
  "SHORT_LINKS_PROTOCOL", Rails.env.development? || Rails.env.test? ? "http" : "https"
).to_s.strip.downcase
raw_port = ENV["SHORT_LINKS_PORT"].presence
config.port = raw_port && Integer(raw_port, 10)

raise "SHORT_LINKS_HOST must be present" if config.host.blank?
raise "SHORT_LINKS_PROTOCOL must be http or https" unless %w[http https].include?(config.protocol)
unless config.port.nil? || (1..65_535).cover?(config.port)
  raise "SHORT_LINKS_PORT must be between 1 and 65535"
end

public_app_url = ENV["PUBLIC_APP_URL"].presence
raise "PUBLIC_APP_URL must be configured in production" if Rails.env.production? && public_app_url.blank?

config.public_app_url = public_app_url || "http://localhost:3000"
Rails.application.config.x.short_links = config
Rails.application.config.x.public_app_url = config.public_app_url
