module Admin
  class OrganizationMembershipsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Membership
    self.parent_class = Organizations::Organization
    self.parent_param = :organization_id
    self.parent_association = :memberships

    auditable on: %i[create update destroy]

    def create
      if params.dig(:membership, :role) == "owner"
        return render_error(errors: [ "Cannot assign owner role through membership management" ], status: :unprocessable_entity)
      end
      super
    end

    def update
      if params.dig(:membership, :role) == "owner"
        return render_error(errors: [ "Cannot assign owner role through membership management" ], status: :unprocessable_entity)
      end
      super
    end

    private

    def model_params
      params.require(:membership).permit(:user_id, :role)
    end

    def allowed_order_columns
      %w[id role created_at updated_at]
    end

    def serializer_profile
      {
        default: { fields: %i[id role created_at updated_at], include: %i[user] },
        index: { fields: %i[id role created_at updated_at], include: %i[user] },
        show: { fields: %i[id role created_at updated_at], include: %i[user] },
        create: { fields: %i[id role created_at updated_at], include: %i[user] },
        update: { fields: %i[id role created_at updated_at], include: %i[user] }
      }
    end
  end
end
