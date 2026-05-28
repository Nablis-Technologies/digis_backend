module Organizations
  class Organization < Organizations::ApplicationRecord
    self.table_name = "organizations_organizations"

    include Core::AuditableModel
    include Core::Slugable
    slugable source: :name, target: :slug

    has_many :memberships,
             class_name: "Organizations::Membership",
             dependent: :destroy
    has_one :owner_membership,
            -> { where(role: :owner) },
            class_name: "Organizations::Membership"

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true

    def owner
      owner_membership&.user
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name slug description created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[memberships]
    end
  end
end
