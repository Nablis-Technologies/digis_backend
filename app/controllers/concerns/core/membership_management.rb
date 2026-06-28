module Core
  module MembershipManagement
    extend ActiveSupport::Concern

    included do
      self.model_class = Organizations::Membership
      self.parent_class = Organizations::Organization
      self.parent_association = :memberships

      auditable on: %i[create update destroy]
    end

    def create
      return render_owner_role_guard if params.dig(:membership, :role) == "owner"
      super
    end

    def update
      return render_owner_role_guard if params.dig(:membership, :role) == "owner"
      super
    end

    private

    def render_owner_role_guard
      render_error(message: :"membership.errors.owner_role_assignment", status: :unprocessable_entity)
    end

    def model_params
      params.require(:membership).permit(:user_id, :role, :status)
    end

    def eager_load_config
      { default: [ :user ] }
    end

    def allowed_order_columns
      %w[id role status created_at updated_at]
    end

    def serializer_profile
      {
        default: { fields: %i[id role status created_at updated_at], include: %i[user] },
        index:   { fields: %i[id role status created_at updated_at], include: %i[user] },
        show:    { fields: %i[id role status created_at updated_at], include: %i[user] },
        create:  { fields: %i[id role status created_at updated_at], include: %i[user] },
        update:  { fields: %i[id role status created_at updated_at], include: %i[user] }
      }
    end
  end
end
