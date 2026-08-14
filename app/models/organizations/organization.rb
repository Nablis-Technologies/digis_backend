module Organizations
  class Organization < Organizations::ApplicationRecord
    self.table_name = "organizations_organizations"

    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable
    include Core::ReviewableModel

    slugable source: :name, target: :slug

    has_one_attached :profile
    has_one_attached :banner
    has_one_attached :business_license
    has_one_attached :tin_certificate

    has_many :memberships,
             class_name: "Organizations::Membership",
             dependent: :destroy
    has_many :finance_ledger_entries,
             class_name: "Finance::LedgerEntry",
             dependent: :restrict_with_exception,
             inverse_of: :organization
    has_many :finance_payouts,
             class_name: "Finance::Payout",
             dependent: :restrict_with_exception,
             inverse_of: :organization
    has_many :scanner_devices,
             class_name: "Ticketing::ScannerDevice",
             dependent: :restrict_with_exception
    has_many :legal_acceptances,
             -> { where(subject_type: "organization") },
             class_name: "Legal::LegalAcceptance",
             foreign_key: :subject_id,
             dependent: :restrict_with_exception
    has_one :owner_membership,
            -> { where(role: :owner) },
            class_name: "Organizations::Membership"

    validates :name, presence: true, uniqueness: true
    validates :slug, presence: true, uniqueness: true

    scope :archived, -> { where(archived: true) }
    scope :not_archived, -> { where(archived: false) }
    validates :events_count, numericality: { greater_than_or_equal_to: 0 }
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

    validates :organizer_type, presence: true,
              inclusion: { in: %w[individual company ngo government collective] }
    validates :category, presence: true,
              inclusion: { in: %w[music sports conference comedy theater festival workshop exhibition other] }

    validates :estimated_audience,
              inclusion: { in: %w[under_100 100_500 500_1000 1000_5000 5000_plus] }, allow_nil: true
    validates :event_frequency,
              inclusion: { in: %w[one_time monthly quarterly weekly seasonal] }, allow_nil: true

    def owner
      owner_membership&.user
    end

    def verified?
      if reviews.loaded?
        reviews.any? { |r| r.context == "verification" && r.status == "approved" }
      else
        approved?(:verification)
      end
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[name slug description organizer_type category city region created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[memberships reviews]
    end
  end
end
