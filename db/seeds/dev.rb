# frozen_string_literal: true

# Local development uses the same comprehensive preview fixtures plus any
# explicitly local-only extensions.
ENV["DIGIS_SEED_PROFILE"] = "dev"
load Rails.root.join("db/seeds.rb")
