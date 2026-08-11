module Organizations
  class OwnershipTransferService
    def self.transfer(organization, current_owner_user, new_owner_user)
      new_membership = organization.memberships.active.find_by(user_id: new_owner_user.id)
      raise ActiveRecord::RecordNotFound,
        I18n.t("core.errors.ownership_transfer_member_required") unless new_membership

      organization.transaction do
        old_membership = organization.memberships.active.find_by!(user_id: current_owner_user.id, role: :owner)

        old_membership.update_column(:role, :admin)
        new_membership.update!(role: :owner)
      end
    end
  end
end
