# frozen_string_literal: true

# Marketplace payout registration is independent from checkout registration,
# while sharing Finance's Chapa V2 payout transport and environment guard.
Rails.application.config.after_initialize do
  Marketplace::PayoutProviders::Registration.call
end
