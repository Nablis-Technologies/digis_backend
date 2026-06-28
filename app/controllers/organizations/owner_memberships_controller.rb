module Organizations
  class OwnerMembershipsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::MembershipManagement

    self.parent_class = Organizations::Organization
    self.parent_param = :owner_organization_organization_id

    before_action :set_object, only: %i[show update destroy suspend activate]

    def destroy
      if @obj.role == "owner" && @obj.user_id == current_user.id
        return render_error(:"membership.errors.transfer_ownership_required",
                            status: :unprocessable_entity)
      end
      super
    end

    def suspend
      authorize @obj
      @obj.update!(status: :suspended)
      render_success
    end

    def activate
      authorize @obj
      @obj.update!(status: :active)
      render_success
    end
  end
end
