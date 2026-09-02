# frozen_string_literal: true

module Events
  class EventPolicy < Core::ApplicationPolicy
    ORGANIZER_FIELDS = %i[
      id title slug description status visibility timezone currency version
      published_at cancelled_at created_at organization categories event_dates event_media
    ].freeze

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
        default: { fields: ORGANIZER_FIELDS, include: [] },
        admin: { fields: :all, include: [] }
      },
      show: {
        default: { fields: ORGANIZER_FIELDS, include: [] },
        admin: { fields: :all, include: [ :event_setting ] }
      },
      public_show: {
        default: {
          fields: %i[id title slug description visibility timezone currency published_at created_at],
          include: [],
          association_fields: {
            categories: { fields: %i[id name description slug metadata active created_at updated_at] },
            event_dates: {
              fields: %i[id name doors_at starts_at ends_at status venue],
              association_fields: { venue: { fields: %i[id name city] } }
            },
            event_media: { fields: %i[id type position alt_text caption file] },
            event_organizations: {
              fields: %i[id type role status organization],
              association_fields: { organization: { fields: %i[id name slug] } }
            },
            event_setting: { fields: %i[id config] },
            organization: { fields: %i[id name slug] }
          }
        },
        admin: { fields: :all, include: [] }
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
