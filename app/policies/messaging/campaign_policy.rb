# frozen_string_literal: true

module Messaging
  # Organization boundary and safe campaign response visibility.
  class CampaignPolicy < Core::ApplicationPolicy
    FIELDS = %i[id organization_id created_by_id event_id name channel status timezone launch_version send_at launched_at
                completed_at canceled_at variables quoted_quantity quoted_unit_price_minor quoted_rate_version_id quoted_at quote_expires_at].freeze

    def index? = organization_member?
    def show? = organization_member?
    def create? = organization_admin?
    def update? = organization_admin?
    def estimate? = organization_admin?
    def attest? = organization_admin?
    def launch? = organization_admin?
    def pause? = organization_admin?
    def resume? = organization_admin?
    def cancel? = organization_admin?
    def abort? = organization_admin?
    def analytics? = organization_member?

    VISIBILITY = %i[index show create update estimate attest launch pause resume cancel abort analytics].to_h do |action|
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
