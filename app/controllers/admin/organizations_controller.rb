module Admin
  class OrganizationsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Organization
    self.default_serializer = ::Admin::OrganizationSerializer

    auditable on: %i[create update destroy transfer_ownership]

    def create
      unless params.dig(:organization, :owner_id)
        return render_error(:"admin.organizations.errors.owner_id_required",
                            status: :unprocessable_entity)
      end
      super
    end

    def transfer_ownership
      set_clazz
      set_object
      authorize @obj, :transfer_ownership?

      new_owner = Core::User.find_by(id: params.dig(:organization, :new_owner_id))
      unless new_owner
        return render_error(:"admin.organizations.errors.new_owner_id_invalid",
                            status: :unprocessable_entity)
      end

      ActiveRecord::Base.transaction do
        @obj.with_lock do
          current_owner_membership = @obj.owner_membership
          return render_error(:"admin.organizations.errors.no_current_owner",
                              status: :unprocessable_entity) unless current_owner_membership

          current_owner_membership.update!(role: :admin)

          target_membership = @obj.memberships.lock.find_by(user: new_owner)
          if target_membership
            target_membership.update!(role: :owner)
          else
            begin
              @obj.memberships.create!(user: new_owner, role: :owner)
            rescue ActiveRecord::RecordNotUnique
              # Race: another process created the membership. Re-find and update.
              target_membership = @obj.memberships.lock.find_by(user: new_owner)
              raise unless target_membership
              target_membership.update!(role: :owner)
            end
          end
        end
      end

      @obj = @clazz.with_attached_profile.includes(:memberships, owner_membership: :user).find(@obj.id)
      render_success(data: @obj, serializer_options: { serializer: ::Admin::OrganizationSerializer })
    end

    private

    def allowed_order_columns
      %w[id name slug created_at updated_at]
    end

    def apply_index_scope(scope)
      scope.with_attached_profile.includes(:memberships, owner_membership: :user)
    end

    def model_params
      params.require(:organization).permit(:name, :description, :profile, social_links: {})
    end

    def after_create_hook(organization)
      owner = Core::User.find(params.dig(:organization, :owner_id))
      organization.memberships.create!(user: owner, role: :owner)
    end
  end
end
