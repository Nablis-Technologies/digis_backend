# frozen_string_literal: true

Rails.application.config.x.marketing_featured_placements_enabled =
  ENV["MARKETING_FEATURED_PLACEMENTS_ENABLED"] == "true"
