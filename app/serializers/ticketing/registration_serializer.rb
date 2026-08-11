# frozen_string_literal: true

module Ticketing
  # Public registration projection. Deliberately omits identity_digest, user,
  # audience proofs, and form answers to avoid exposing personal data.
  class RegistrationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :ticket_type_id, :selected_event_date_id, :source,
               :package_quantity, :admissions_per_unit_snapshot, :party_size, :status,
               :next_action_snapshot,
               :submitted_at, :waitlisted_at, :offered_at, :offer_expires_at, :approved_at,
               :rejected_at, :confirmed_at, :cancelled_at, :created_at, :updated_at
  end
end
