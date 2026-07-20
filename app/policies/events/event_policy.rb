# frozen_string_literal: true

module Events
  class EventPolicy < Core::ApplicationPolicy
    def index?
      user.present?
    end

    def show?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")
      return true if record.visibility == "public" && record.published?

      owner_or_collaborator?(record) || staff_of?(record)
    end

    def create?
      user.present?
    end

    def update?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")
      return false if record.published?

      owner_or_collaborator?(record) || manager_of?(record)
    end

    def publish?
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")
      return false unless record.organization.verified?

      owner_or_collaborator?(record) || manager_of?(record)
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id title slug status visibility created_at], include: [] },
        admin: { fields: :all, include: [] }
      },
      show: {
        default: { fields: %i[id title slug description status visibility timezone currency version published_at created_at], include: [] },
        admin: { fields: :all, include: [ :event_setting ] }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")

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
      organization = event.organization
      return false unless organization

      Organizations::Membership
        .where(user:, organization:, status: "active")
        .where(role: %w[owner admin manager])
        .exists?
    end

    def manager_of?(event)
      event.event_staff_assignments
          .managers
          .where(user:)
          .exists?
    end

    def staff_of?(event)
      event.event_staff_assignments
          .active
          .where(user:)
          .exists?
    end
  end
end
