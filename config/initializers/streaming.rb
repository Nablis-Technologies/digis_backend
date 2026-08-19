# frozen_string_literal: true

default_providers = Rails.env.production? ? "" : "youtube"
Rails.application.config.x.streaming.enabled_providers =
  ENV.fetch("STREAMING_ENABLED_PROVIDERS", default_providers).split(",").map(&:strip).reject(&:empty?)
