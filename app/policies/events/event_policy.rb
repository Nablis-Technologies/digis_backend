# frozen_string_literal: true

module Events
  class EventPolicy < Core::ApplicationPolicy
    def index?
      user.present?
    end

    def show?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
      return true if record.visibility == "public" && record.published?

      owner_or_collaborator?(record) || staff_of?(record)
    end

    def create?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

      org = record.is_a?(Events::Event) ? record.organization : nil
      return false unless org

      Organizations::Membership
        .where(user:, organization: org, status: "active")
        .where(role: %w[owner admin])
        .exists?
    end

    def update?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
      return false if record.published?

      owner_or_collaborator?(record) || manager_of?(record)
    end

    def publish?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
      return false unless record.organization.verified?

      owner_or_collaborator?(record) || manager_of?(record)
    end

    def complete?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

      Events::AuthorizationResolver.organization_admin_or_owner?(user, record)
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id title slug status visibility created_at], include: [] },
        admin: { fields: :all, include: [] }
      },
      show: {
        default: { fields: %i[id title slug description status visibility timezone currency version published_at created_at], include: [] },
        admin: { fields: :all, include: [ :event_setting ] }
      },
      complete: {
        default: { fields: %i[id title slug description status visibility timezone currency version published_at completed_at created_at updated_at], include: [] },
        admin: { fields: :all, include: [] }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

        scope.where(
          organization_id: owned_organization_ids
        ).or(scope.where(visibility: "public", status: "published"))
      end

      private

      def owned_organization_ids
        Organizations::Membership
          .where(user: user, status: "active")
          .where(role: %w[owner admin manager])
          .pluck(:organization_id)
      end
    end

    private

    def owner_or_collaborator?(event)
      Events::AuthorizationResolver.organization_admin_or_owner?(user, event)
    end

    def manager_of?(event)
      Events::AuthorizationResolver.role_for(user, event) == :manager
    end

    def staff_of?(event)
      Events::AuthorizationResolver.role_for(user, event).in?(%i[staff scanner contractor])
    end
  end
end
