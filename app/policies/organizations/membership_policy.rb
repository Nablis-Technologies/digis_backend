module Organizations
  class MembershipPolicy < Core::ApplicationPolicy
    ROLE_WEIGHT = { owner: 3, admin: 2, staff: 1 }.freeze

    def index?
      return true if user.super_admin?
      org_id = record.organization_id || record.organization&.id
      return false unless org_id
      Organizations::Membership.active.exists?(user_id: user.id, organization_id: org_id)
    end

    def show?
      can_manage?
    end

    def create?
      can_manage?
    end

    def update?
      can_manage?
    end

    def destroy?
      can_manage?
    end

    def suspend?
      can_manage?
    end

    def activate?
      can_manage?
    end

    def can_manage?
      return true if user.super_admin?
      return false unless current_membership

      actor_weight = ROLE_WEIGHT[current_membership.role.to_sym]
      target_weight = ROLE_WEIGHT[record.role.to_sym]
      actor_weight > target_weight
    end

    private

    def current_membership
      @current_membership ||= Organizations::Membership.active
        .find_by(user_id: user.id, organization_id: record.organization_id)
    end

    VISIBILITY = {
      index: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } },
      show: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } },
      create: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } },
      update: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } },
      destroy: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } },
      suspend: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } },
      activate: { admin: { include: :all, fields: :all }, default: { include: :all, fields: :all } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user.super_admin?
        org_ids = Organizations::Organization.joins(:memberships)
                     .where(organizations_memberships: { user_id: user.id })
                     .select(:id)
        scope.where(organization_id: org_ids)
      end
    end
  end
end
