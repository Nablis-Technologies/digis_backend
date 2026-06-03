module Organizations
  class OwnerOrganizationsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Organization

    auditable on: %i[create update destroy]

    def set_object
      @obj = @clazz.joins(:memberships)
                   .where(organizations_memberships: { user_id: current_user.id })
                   .includes(eager_loaded_associations)
                   .find_by!(self.class.resource_param => params[self.class.resource_param])
    end

    private

    def apply_index_scope(scope)
      scope.joins(:memberships)
           .where(organizations_memberships: { user_id: current_user.id })
           .includes(:memberships)
    end

    def model_params
      params.require(:organization).permit(:name, :description, :profile, social_links: {})
    end

    def allowed_order_columns
      %w[id name slug created_at updated_at]
    end

    def after_create_hook(organization)
      organization.memberships.create!(user: current_user, role: :owner)
    end

    def serializer_profile
      {
        index: { fields: %i[id name slug description created_at] },
        show: { fields: %i[id name slug description profile_url social_links followers_count created_at] },
        create: { fields: %i[id name slug description created_at] },
        update: { fields: %i[id name slug description created_at] }
      }
    end
  end
end
