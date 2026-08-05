module Events
  class Venue < Events::ApplicationRecord
    self.table_name = "events_venues"

    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached  :profile
    has_many_attached :photos

    validates :name, presence: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }
    validate  :photos_count_within_limit

    scope :by_city, ->(city) { where(city: city) }
    scope :by_country, ->(country) { where(country: country) }
    scope :verified, -> { where(verified: true) }
    scope :active, -> { where(active: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[name city country verified active created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end

    private

    def profile_must_be_attached
       errors.add(:profile, I18n.t("events.venue.errors.profile_required")) unless profile.attached?
    end

    def photos_count_within_limit
       errors.add(:photos, I18n.t("events.venue.errors.photos_limit", maximum: 10)) if photos.count > 10
    end
  end
end
