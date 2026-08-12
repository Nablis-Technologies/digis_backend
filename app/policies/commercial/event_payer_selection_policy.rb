# frozen_string_literal: true

module Commercial
  # Restricts the only organizer Commercial write to events owned by the
  # organizer's organization; the command still rechecks component scope and
  # permitted payer choice under its transaction lock.
  class EventPayerSelectionPolicy < Core::ApplicationPolicy
    def index? = member_of_event?
    def show? = member_of_event?
    def create? = member_of_event?

    VISIBILITY = {
      index: { admin: { fields: :all, include: [] }, default: { fields: %i[id event_id fee_component_id charged_to selected_at], include: [] } },
      show: { admin: { fields: :all, include: [] }, default: { fields: %i[id event_id fee_component_id charged_to selected_at], include: [] } },
      create: { admin: { fields: :all, include: [] }, default: { fields: %i[id event_id fee_component_id charged_to selected_at], include: [] } }
    }.freeze

    private

    def member_of_event?
      user&.super_admin? || record.event && user&.member_of?(record.event.organization)
    end
  end
end
