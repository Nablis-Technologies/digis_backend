# frozen_string_literal: true

module Organizations
  class MembershipInvitationPolicy < Core::ApplicationPolicy
    def index? = can_manage_scope?
    def claim? = user.present?

    def create? = can_manage_scope?

    def resend? = manage_requested_role?
    def revoke? = manage_requested_role?

    VISIBILITY = {
      index: { default: { fields: %i[id organization_id role contact_type masked_contact status delivery_status delivery_revision expires_at accepted_at revoked_at expired_at created_at], include: [] } },
      create: { default: { fields: %i[id organization_id role contact_type masked_contact status delivery_status delivery_revision expires_at created_at], include: [] } },
      resend: { default: { fields: %i[id organization_id role contact_type masked_contact status delivery_status delivery_revision expires_at created_at], include: [] } },
      revoke: { default: { fields: %i[id organization_id role contact_type masked_contact status delivery_status delivery_revision expires_at revoked_at created_at], include: [] } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.super_admin?

        organization_ids = Organizations::Membership.active
          .where(user:, role: %w[owner admin])
          .select(:organization_id)
        scope.where(organization_id: organization_ids)
      end
    end

    private

    def can_manage_scope?
      return true if user&.super_admin?
      return false unless user && record.organization_id.present?

      Organizations::Membership.active.where(
        user_id: user.id,
        organization_id: record.organization_id,
        role: %w[owner admin]
      ).exists?
    end

    def manage_requested_role?
      return false unless user && record.organization

      membership = Organizations::Membership.new(organization: record.organization, role: record.role)
      Organizations::MembershipPolicy.new(user, membership).update?
    end
  end
end
