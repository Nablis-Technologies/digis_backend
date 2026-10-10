# frozen_string_literal: true

# Configure these only when a real phone-delivery provider is selected. Nil is
# intentional: delivery jobs record `unknown`/unavailable and preserve the
# organizer's one-time manual share link instead of claiming SMS was sent.
Rails.application.config.x.membership_invitation_delivery_sender ||= nil
Rails.application.config.x.staff_invitation_delivery_sender ||= nil
