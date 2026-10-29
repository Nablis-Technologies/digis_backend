module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
    VERIFICATION_FIELDS = %i[
      verification_status verification_feedback has_business_license has_tin_certificate
    ].freeze

    def index?
      true
    end

    def show?
      true
    end

    def create?
      true
    end

    def update?
      record.owner == user || user&.super_admin?
    end

    def destroy?
      record.owner == user || user&.super_admin?
    end

    def download_documents?
      record.owner == user || user&.super_admin?
    end

    def visible_attributes_for(record:, action:)
      fields = super
      return fields unless action.to_sym == :show && fields.present?
      return fields if verification_manager?(record)

      fields - VERIFICATION_FIELDS
    end

    def follow?
      true
    end

    def unfollow?
      true
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description profile_url
                              city region events_count follower_count
                              memberships_count verified membership_status
                              membership_role archived created_at] },
        admin: { include: :all, fields: :all }
      },
      show: {
        default: { fields: %i[id name slug description profile_url banner_url
                              social_links follower_count memberships_count
                              organizer_type category contact_phone contact_email website_url
                              tin_number address_line1 address_line2 city region
                                estimated_audience event_frequency
                              events_count verified is_following verification_status
                              verification_feedback has_business_license has_tin_certificate
                              membership_status membership_role archived
                              created_at] },
        admin: { include: :all, fields: :all }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end

    private

    def verification_manager?(organization)
      return false unless user

      memberships = organization.association(:memberships)
      return memberships.target.any? do |membership|
        membership.user_id == user.id && membership.status == "active" && membership.role.in?(%w[owner admin])
      end if memberships.loaded?

      Organizations::Membership.exists?(
        organization_id: organization.id,
        user_id: user.id,
        status: "active",
        role: %w[owner admin]
      )
    end
  end
end
