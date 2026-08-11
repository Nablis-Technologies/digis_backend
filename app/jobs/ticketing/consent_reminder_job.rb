# frozen_string_literal: true

module Ticketing
  # Bounded, payload-free reminder boundary. It writes one durable outbox signal
  # per requirement/day; a configurable sender seam owns eventual delivery.
  class ConsentReminderJob < ApplicationJob
    queue_as :default

    def perform(limit = 100)
      batch_size = limit.to_i.clamp(1, 100)
      requirements = Ticketing::RegistrationConsentRequirement
        .where(status: "pending", required: true)
        .where("required_at <= ?", Time.current)
        .order(:required_at, :id)
        .limit(batch_size)
        .to_a
      requirements.each do |requirement|
        Core::Outbox::Publish.call(
          topic: "ticketing.consent",
          event_type: "ticketing.registration_consent.reminder_due",
          aggregate: requirement,
          payload: { requirement_id: requirement.id },
          idempotency_key: "ticketing-consent-reminder-#{requirement.id}-#{requirement.required_at.to_date}"
        )
      end
      requirements.size
    end
  end
end
