# frozen_string_literal: true

module Catalog
  class ProductQuotePolicy < Core::ApplicationPolicy
    def create? = admin?

    VISIBILITY = {
      create: {
        default: { fields: [], include: [] },
        admin: { include: :all, fields: :all }
      }
    }

    private

    def admin?
      user_role_key == :admin
    end
  end
end
