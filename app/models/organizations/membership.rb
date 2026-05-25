module Organizations
  class Membership < Organizations::ApplicationRecord
    self.table_name = "organizations_memberships"

    belongs_to :user, class_name: "Core::User"
    belongs_to :organization, class_name: "Organizations::Organization"

    enum :role, { owner: 0, admin: 1, member: 2 }

    validates :role, presence: true
    validates :role, uniqueness: { scope: :organization_id,
                                    message: "already exists for this organization" },
             if: -> { owner? }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id organization_id role created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user organization]
    end
  end
end
