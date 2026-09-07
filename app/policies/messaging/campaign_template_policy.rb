# frozen_string_literal: true

module Messaging
  class CampaignTemplatePolicy < Core::ApplicationPolicy
    FIELDS = %i[id organization_id created_by_id name channel status created_at updated_at].freeze

    def index? = organization_member?
    def show? = organization_member?
    def create? = organization_admin?
    def update? = organization_admin?

    VISIBILITY = %i[index show create update].to_h do |action|
      [ action, { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } } ]
    end.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        scope.where(organization_id: [ user.organizations.where(archived: false).select(:id), nil ])
      end
    end

    private

    def organization_member?
      return true if user&.super_admin?
      return true if record.organization_id.nil?

      user&.member_of?(record.organization)
    end

    def organization_admin?
      return true if user&.super_admin?

      record.organization && Events::AuthorizationResolver.organization_admin?(user, record.organization)
    end
  end
end
