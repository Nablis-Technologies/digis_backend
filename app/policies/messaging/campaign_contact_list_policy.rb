# frozen_string_literal: true

module Messaging
  class CampaignContactListPolicy < Core::ApplicationPolicy
    FIELDS = %i[id organization_id created_by_id name status version entries_count created_at updated_at].freeze

    def index? = organization_member?
    def show? = organization_member?
    def create? = organization_admin?
    def update? = organization_admin?
    def destroy? = organization_admin?
    def import? = organization_admin?
    def append? = organization_admin?
    def replace? = organization_admin?

    VISIBILITY = %i[index show create update destroy import append replace].to_h do |action|
      [ action, { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } } ]
    end.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        scope.where(organization_id: user.organizations.where(archived: false).select(:id))
      end
    end

    private

    def organization_member?
      return true if user&.super_admin?

      record.organization && user&.member_of?(record.organization)
    end

    def organization_admin?
      Events::AuthorizationResolver.organization_admin?(user, record.organization)
    end
  end
end
