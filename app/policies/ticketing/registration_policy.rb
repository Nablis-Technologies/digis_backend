# frozen_string_literal: true

module Ticketing
  # Registrations are visible only to their registrant or event organizers;
  # phone-derived identity and audience proofs never leave this policy boundary.
  class RegistrationPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id event_id ticket_type_id selected_event_date_id source package_quantity
      admissions_per_unit_snapshot party_size status next_action_snapshot submitted_at waitlisted_at
      offered_at offer_expires_at approved_at rejected_at confirmed_at cancelled_at
      created_at updated_at
    ].freeze

    def show? = organizer? || registrant?
    def create? = user.present? && record.user_id == user.id
    def approve? = organizer?
    def reject? = organizer?
    def reconsider? = organizer?
    def offer_next? = organizer?
    def enqueue_waitlist? = organizer? || registrant?
    def accept_waitlist_offer? = registrant?
    def complimentary? = organizer?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      approve: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      reject: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      reconsider: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      offer_next: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      enqueue_waitlist: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      accept_waitlist_offer: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      complimentary: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        organizer_event_ids = Events::AuthorizationResolver.manageable_catalog_events(user).select(:id)
        scope.where(user_id: user.id).or(scope.where(event_id: organizer_event_ids))
      end
    end

    private

    def organizer?
      record.event.present? && Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end

    def registrant?
      record.user_id == user&.id
    end
  end
end
