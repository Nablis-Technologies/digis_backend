module Events
  class Artist < Events::ApplicationRecord
    self.table_name = "events_artists"

    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached :profile

    validates :name, presence: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

    scope :by_genre, ->(genre) { where("genres @> ?", [ genre ].to_json) }
    scope :verified, -> { where(verified: true) }
    scope :active, -> { where(active: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[name verified active created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end
  end
end
