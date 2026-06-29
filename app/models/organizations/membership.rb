module Organizations
  class Membership < Organizations::ApplicationRecord
    self.table_name = "organizations_memberships"

    include Core::AuditableModel

    belongs_to :user, class_name: "Core::User"
    belongs_to :organization, class_name: "Organizations::Organization"

    enum :role, { owner: "owner", admin: "admin", staff: "staff" }
    enum :status, { active: "active", suspended: "suspended" }

    scope :active, -> { where(status: :active) }

    validates :role, presence: true
    validates :status, presence: true, inclusion: { in: %w[active suspended] }

    before_update :prevent_sole_owner_suspension, if: :will_save_change_to_status?
    before_update :prevent_sole_owner_demotion, if: :will_save_change_to_role?
    before_destroy :prevent_sole_owner_removal, if: -> { owner? }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id organization_id role status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user organization]
    end

    private

    def prevent_sole_owner_suspension
      return unless status == "suspended"
      return if organization.memberships.active.owner.where.not(id: id).exists?

      errors.add(:base, "Cannot suspend the sole owner. Transfer ownership first.")
      throw :abort
    end

    def prevent_sole_owner_demotion
      return unless role_was == "owner"
      return if organization.memberships.active.owner.where.not(id: id).exists?

      errors.add(:base, "Cannot demote the sole owner. Transfer ownership first.")
      throw :abort
    end

    def prevent_sole_owner_removal
      return unless active?
      return if organization.memberships.active.owner.where.not(id: id).exists?

      errors.add(:base, "Cannot remove the sole owner. Transfer ownership first.")
      throw :abort
    end
  end
end
