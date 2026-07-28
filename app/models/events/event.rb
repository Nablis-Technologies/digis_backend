# frozen_string_literal: true

module Events
  class Event < Events::ApplicationRecord
    self.table_name = "events_events"

    include Core::AuditableModel
    include Core::Slugable
    slugable source: :title, target: :slug

    STATUSES = %w[draft published cancelled completed].freeze
    VISIBILITIES = %w[public private].freeze
    MAX_CATEGORIES = 3


    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :created_by, class_name: "Core::User"

    has_one :event_setting, class_name: "Events::EventSetting",
            dependent: :destroy, inverse_of: :event
    has_many :event_categories, class_name: "Events::EventCategory",
             dependent: :destroy, inverse_of: :event
    has_many :categories, through: :event_categories, source: :category
    has_many :event_organizations, class_name: "Events::EventOrganization",
             dependent: :destroy, inverse_of: :event
    has_many :collaborators, through: :event_organizations, source: :organization
    has_many :event_staff_assignments, class_name: "Events::EventStaffAssignment",
              dependent: :destroy, inverse_of: :event
    has_many :event_dates, class_name: "Events::EventDate",
             dependent: :destroy, inverse_of: :event
    has_one :recurrence_rule, class_name: "Events::RecurrenceRule",
            dependent: :destroy, inverse_of: :event
    has_many :event_participants, class_name: "Events::EventParticipant",
             dependent: :destroy, inverse_of: :event
    has_many :access_zones, class_name: "Events::AccessZone",
             dependent: :destroy, inverse_of: :event
    has_many :event_video_links, class_name: "Events::EventVideoLink",
             dependent: :destroy, inverse_of: :event
    has_many :event_media, class_name: "Events::EventMedia",
             dependent: :destroy, inverse_of: :event
    has_many :event_streams, class_name: "Events::EventStream",
             through: :event_dates
    has_many :consent_documents, class_name: "Events::ConsentDocument",
             dependent: :destroy, inverse_of: :event
    has_many :event_products, class_name: "Catalog::EventProduct",
             dependent: :destroy, inverse_of: :event

    validates :title, presence: true
    validates :slug, presence: true,
                      uniqueness: { case_sensitive: false, message: :slug_taken }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
    validates :version, numericality: { greater_than_or_equal_to: 0, only_integer: true }
    validates :currency, format: { with: /\A[A-Z]{3}\z/, message: :invalid_currency }
    validate :timezone_must_be_valid
    validate :published_at_requires_published
    validate :cancelled_at_requires_cancelled
    validate :category_count_within_limit, on: :update

    before_validation :sync_published_at
    before_validation :sync_cancelled_at

    scope :published, -> { where(status: "published") }
    scope :drafts, -> { where(status: "draft") }
    scope :publicly_visible, -> { where(status: "published", visibility: "public") }

    def published?
      status == "published"
    end

    def cancelled?
      status == "cancelled"
    end

    private

    def timezone_must_be_valid
      return if timezone.blank?

      TZInfo::Timezone.get(timezone)
    rescue TZInfo::InvalidTimezoneIdentifier
      errors.add(:timezone, I18n.t("errors.messages.invalid_timezone"))
    end

    def published_at_requires_published
      return unless published_at.present? && !%w[published cancelled].include?(status)

      errors.add(:published_at, I18n.t("errors.messages.published_at_requires_published"))
    end

    def cancelled_at_requires_cancelled
      return unless cancelled_at.present? && status != "cancelled"

      errors.add(:cancelled_at, I18n.t("errors.messages.cancelled_at_requires_cancelled"))
    end

    def sync_published_at
      if status == "published"
        self.published_at ||= Time.current
      elsif status != "cancelled"
        # A cancelled event retains published_at as historical evidence that it
        # was once live; every other non-published status clears it.
        self.published_at = nil
      end
    end

    def sync_cancelled_at
      if status == "cancelled"
        self.cancelled_at ||= Time.current
      else
        self.cancelled_at = nil
      end
    end

    def category_count_within_limit
      return unless event_categories.reload.count > MAX_CATEGORIES

      errors.add(:categories, I18n.t("events.event.errors.too_many_categories",
                                     max: MAX_CATEGORIES))
    end
  end
end
