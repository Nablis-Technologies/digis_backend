# frozen_string_literal: true

surface_limit = begin
  Integer(ENV.fetch("MARKETING_FEATURED_PUBLIC_DISCOVERY_MAX_CONCURRENT", ""), 10)
rescue ArgumentError, TypeError
  nil
end

Rails.application.config.x.marketing_featured_max_concurrent_by_surface =
  { "public_discovery" => surface_limit }.compact
Rails.application.config.x.marketing_featured_placements_enabled =
  ENV["MARKETING_FEATURED_PLACEMENTS_ENABLED"] == "true"
