# frozen_string_literal: true

# Payout registration is separate from payment registration so enabling Chapa
# checkout cannot accidentally enable organizer payout dispatch.
Rails.application.config.after_initialize do
  Finance::PayoutProviders::Registration.call
end
