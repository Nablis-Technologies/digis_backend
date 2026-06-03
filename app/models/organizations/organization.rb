module Organizations
  class Organization < Organizations::ApplicationRecord
    self.table_name = "organizations_organizations"

    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached :profile
    has_many :memberships,
             class_name: "Organizations::Membership",
             dependent: :destroy
    has_one :owner_membership,
            -> { where(role: :owner) },
            class_name: "Organizations::Membership"

    validates :name, presence: true, uniqueness: true
    validates :slug, presence: true, uniqueness: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

    def owner
      owner_membership&.user
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[name slug description created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[memberships]
    end
  end
end
