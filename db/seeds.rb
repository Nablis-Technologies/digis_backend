# frozen_string_literal: true

# Selects the seed profile explicitly. Production defaults to the safe base;
# preview and development profiles must be opted into by deployment/CI config.
profile = ENV.fetch("DIGIS_SEED_PROFILE", "base").to_sym
preview_runtime = ENV["RENDER_PREVIEW"] == "true" &&
  ENV["RENDER_PREVIEW_DATABASE_URL"].present?

unless %i[base preview dev].include?(profile)
  raise "Unknown DIGIS_SEED_PROFILE=#{profile.inspect}"
end

if Rails.env.production? && profile != :base && !preview_runtime
  raise "Refusing to seed #{profile} data in production"
end

load Rails.root.join("db/seeds/base.rb")

case profile
when :preview
  load Rails.root.join("db/seeds/preview.rb")
when :dev
  load Rails.root.join("db/seeds/preview.rb")
  load Rails.root.join("db/seeds/dev_extensions.rb")
end
