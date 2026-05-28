module Events
  class Category < Events::ApplicationRecord
    self.table_name = "events_categories"

    include Core::AuditableModel
    include Core::Slugable
    slugable source: :name, target: :slug

    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :slug, presence: true, uniqueness: true

    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }
    scope :alphabetical, -> { order(:name) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name description slug active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end
  end
end
