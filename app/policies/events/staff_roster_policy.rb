# frozen_string_literal: true

module Events
  class StaffRosterPolicy < Core::ApplicationPolicy
    def show? = Events::AuthorizationResolver.can_assign?(user, record, "staff")

    VISIBILITY = {
      show: { default: { fields: %i[assignments invitations], include: [] } }
    }
  end
end
