# frozen_string_literal: true

module Ticketing
  # Limits the event scanner roster read model to actors allowed to manage scanners.
  class ScannerRosterPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[event_id invitations assignments].freeze

    def index?
      Events::AuthorizationResolver.can_assign?(user, record, "scanner")
    end

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze
  end
end
