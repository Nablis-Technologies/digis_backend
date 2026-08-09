# frozen_string_literal: true

module Ticketing
  # Delivers only an event type and registration ID to the injected messaging
  # boundary; private registration data never travels through the outbox job.
  class RegistrationNotificationJob < ApplicationJob
    queue_as :default

    def perform(registration_id, event_type)
      registration = Ticketing::Registration.find(registration_id)
      Rails.application.config.x.registration_notification_sender.call(
        registration_id: registration.id,
        event_type:
      )
    end
  end
end
