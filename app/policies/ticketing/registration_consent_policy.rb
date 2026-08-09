# frozen_string_literal: true

module Ticketing
  class RegistrationConsentPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id registration_id consent_document_id document_version required acceptance_scope
      package_unit_number admission_position status required_reason required_at superseded_at
      subject_assigned
    ].freeze

    def index? = accessible?
    # Replays must reach the command so the request UUID can return the original
    # acceptance; non-pending fresh requests are rejected by the service.
    def accept? = accessible?
    def withdraw? = original_signer?

    VISIBILITY = {
      index: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } },
      accept: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } },
      withdraw: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        requirements = scope.joins(:registration)
        organizer_events = Events::AuthorizationResolver.manageable_catalog_events(user).select(:id)
        requirements
          .where(ticketing_registrations: { user_id: user.id })
          .or(requirements.where(subject_user_id: user.id))
          .or(requirements.where(ticketing_registrations: { event_id: organizer_events }))
      end
    end

    private

    def accessible?
      registration = record.registration
      return false unless registration
      return true if Events::AuthorizationResolver.can_manage_catalog?(user, registration.event)
      return true if registration.user_id == user&.id

      record.subject_user_id == user&.id
    end

    def original_signer?
      record.accepted_by_user_id == user&.id && user&.verified_at.present?
    end
  end
end
