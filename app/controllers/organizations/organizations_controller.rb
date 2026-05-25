module Organizations
  class OrganizationsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Organizations::Organization
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:organization).permit(:name, :description)
    end

    def allowed_order_columns
      %w[id name slug created_at updated_at]
    end

    def after_create_hook(organization)
      organization.memberships.create!(user: current_user, role: :owner)
    end

    def serializer_profile
      {
        index:  { fields: %i[id name slug description created_at] },
        show:   { fields: %i[id name slug description created_at] },
        create: { fields: %i[id name slug description created_at] },
        update: { fields: %i[id name slug description created_at] }
      }
    end
  end
end
