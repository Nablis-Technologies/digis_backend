# frozen_string_literal: true

module Ticketing
  # Owner-only policy for attendee package commands. Organizer/manager
  # suspension actions are separately authorized against the event catalogue
  # scope so an organizer cannot operate on another event's ticket.
  class TicketPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id event_id event_product_id unit_number admissions_per_unit_snapshot owner_user_id
      current_acquisition_type current_acquisition_product_value_minor current_acquisition_currency
      completed_resale_count credential_mode credential_version status issued_at created_at updated_at
    ].freeze
    WALLET_FIELDS = %i[
      id status unit_number admissions_per_unit_snapshot credential_mode credential_version
      event product ticket_type event_dates admission_slots credentials
    ].freeze

    def index? = user.present?
    def show? = owner?
    def delegate? = owner?
    def cancel_delegation? = owner?
    def reassign_slot? = owner?
    def transfer? = owner?
    def suspend? = manage_event?
    def restore_suspension? = manage_event?
    def resolve_suspension? = manage_event?
    def cancel? = manage_event?

    VISIBILITY = {
      index: { default: { fields: WALLET_FIELDS, include: [] }, admin: { fields: WALLET_FIELDS, include: [] } },
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      delegate: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      cancel_delegation: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      reassign_slot: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      transfer: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      suspend: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      restore_suspension: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      resolve_suspension: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      cancel: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        scope.where(owner_user_id: user.id)
      end
    end

    private

    def owner?
      user.present? && record.owner_user_id == user.id
    end

    def manage_event?
      user.present? && record&.event.present? &&
        Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end
  end
end
