# frozen_string_literal: true

# Registers only explicitly enabled providers after application constants are
# available. Preview defaults remain inert until Render secrets are supplied.
Rails.application.config.after_initialize do
  Payments::Providers::Registration.call
end
