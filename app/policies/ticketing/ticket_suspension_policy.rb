# frozen_string_literal: true

module Ticketing
  # Restricts suspension lifecycle commands to platform administrators and
  # organizers who can manage the ticket's event catalogue.
  class TicketSuspensionPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id ticket_id event_id initiated_by_id reason_code status review_deadline_at
      resolved_by_id resolution_reason resolved_at created_at updated_at
    ].freeze

    def show? = manage_event?
    def create? = manage_event?
    def restore? = manage_event?
    def resolve? = manage_event?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      restore: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      resolve: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        event_ids = Events::AuthorizationResolver.manageable_catalog_events(user).select(:id)
        scope.where(event_id: event_ids)
      end
    end

    private

    def manage_event?
      user.present? && record&.event.present? &&
        Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end
  end
end
