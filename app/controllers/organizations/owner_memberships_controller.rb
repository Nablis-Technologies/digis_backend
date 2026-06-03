module Organizations
  class OwnerMembershipsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::MembershipManagement

    self.parent_param = :owner_organization_id

    def destroy
      if @obj.role == "owner" && @obj.user_id == current_user.id
        return render_error(:"membership.errors.transfer_ownership_required",
                            status: :unprocessable_entity)
      end
      super
    end
  end
end
