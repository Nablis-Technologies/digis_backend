# frozen_string_literal: true

module Commercial
  # Authorizes the organizer-facing terms read model by organization
  # membership. The serializer intentionally exposes only safe commercial
  # terms, not the internal admin definition or risk evidence.
  class OrganizationTermsPolicy < Core::ApplicationPolicy
    def show?
      user&.super_admin? || record.organization && user&.member_of?(record.organization)
    end

    def index? = show?

    VISIBILITY = {
      show: { admin: { fields: :all, include: :all }, default: { fields: :all, include: :all } },
      index: { admin: { fields: :all, include: :all }, default: { fields: :all, include: :all } }
    }.freeze
  end
end
