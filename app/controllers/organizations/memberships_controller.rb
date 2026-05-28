module Organizations
  class MembershipsController < Organizations::ApplicationController
    include Core::Common
    self.model_class = Organizations::Membership
    self.parent_class = Organizations::Organization
    self.parent_param = :organization_id
    self.parent_association = :memberships

    private

    def model_params
      params.require(:membership).permit(:user_id, :role)
    end

    def allowed_order_columns
      %w[id role created_at updated_at]
    end

    def serializer_profile
      {
        index:  { fields: %i[id role created_at] },
        show:   { fields: %i[id role created_at] },
        create: { fields: %i[id role created_at] },
        update: { fields: %i[id role created_at] }
      }
    end
  end
end
