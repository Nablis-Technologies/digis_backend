# frozen_string_literal: true

module Catalog
  class ProductQuotePolicy < Core::ApplicationPolicy
    def create? = organizer?

    VISIBILITY = {
      create: {
        default: { fields: :all, include: [] },
        admin: { include: :all, fields: :all }
      }
    }

    private

    def organizer?
      record.present? && Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end
  end
end
