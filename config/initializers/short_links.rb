# frozen_string_literal: true

# Branded links are opt-in. The application remains fully usable through its
# normal routes when the feature or short-link host is not configured.
Rails.application.config.x.short_links = ActiveSupport::OrderedOptions.new
Rails.application.config.x.short_links.enabled = ActiveModel::Type::Boolean.new.cast(
  ENV.fetch("SHORT_LINKS_ENABLED", "false")
)
Rails.application.config.x.short_links.host = ENV.fetch("SHORT_LINKS_HOST", "dig.is")
