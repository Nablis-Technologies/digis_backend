# frozen_string_literal: true

module Finance
  class BuildPayoutsJob < ApplicationJob
    queue_as :default

    def perform(organization_id, currency, idempotency_key, amount_minor: nil, cutoff_at: Time.current)
      Finance::BuildPayout.call(
        organization: Organizations::Organization.find(organization_id),
        currency:,
        idempotency_key:,
        amount_minor:,
        cutoff_at:
      )
    end
  end
end
