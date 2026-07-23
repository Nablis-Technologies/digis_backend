# frozen_string_literal: true

module Events
  class EventMedia < Events::ApplicationRecord
    self.table_name = "events_event_media"
    self.inheritance_column = nil

    TYPES = %w[cover gallery].freeze
    IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
    MAX_GALLERY = 20
    MAX_SIZE = 15.megabytes

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_media
    belongs_to :created_by, class_name: "Core::User", inverse_of: :event_media

    has_one_attached :file do |attachable|
      attachable.variant :cover, resize_to_limit: [ 1200, 1200 ]
      attachable.variant :gallery, resize_to_limit: [ 800, 800 ]
      attachable.variant :thumbnail, resize_to_limit: [ 200, 200 ]
    end

    validates :type, presence: true, inclusion: { in: TYPES }
    validates :created_by, presence: true
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :cover_position_zero
    validate :file_attached
    validate :acceptable_image
    validate :single_cover_per_event
    validate :gallery_within_limit

    scope :for_event, ->(event) { where(event: event) }
    scope :cover, -> { where(type: "cover") }
    scope :gallery, -> { where(type: "gallery") }
    scope :ordered, -> { order(:position) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id created_by_id type position alt_text caption
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event created_by]
    end

    private

    def cover_position_zero
      return unless type == "cover"

      errors.add(:position, "must be 0 for a cover") if position != 0
    end

    def file_attached
      errors.add(:file, "must have an attached image") unless file.attached?
    end

    def acceptable_image
      return unless file.attached?

      unless file.content_type.in?(IMAGE_CONTENT_TYPES)
        errors.add(:file, "must be a JPEG, PNG, or WebP image")
      end
      if file.byte_size > MAX_SIZE
        errors.add(:file, "must be smaller than 15 MB")
      end
    end

    def single_cover_per_event
      return unless type == "cover"
      return if persisted? && !type_changed?

      if event.event_media.cover.where.not(id: id).exists?
        errors.add(:type, "already has a cover")
      end
    end

    def gallery_within_limit
      return unless type == "gallery"

      existing = event.event_media.gallery.where.not(id: id).count
      if existing >= MAX_GALLERY
        errors.add(:base, "can have at most #{MAX_GALLERY} gallery images")
      end
    end
  end
end
