module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
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
                              memberships_count verified created_at] },
        admin: { include: :all, fields: :all }
      },
      show: {
        default: { fields: %i[id name slug description profile_url banner_url
                              business_license_url tin_certificate_url
                              social_links follower_count memberships_count
                              organizer_type category contact_phone contact_email website_url
                              tin_number address_line1 address_line2 city region
                               estimated_audience event_frequency experience_summary
                              events_count verified is_following created_at] },
        admin: { include: :all, fields: :all }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
