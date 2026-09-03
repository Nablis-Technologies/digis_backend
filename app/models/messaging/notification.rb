# frozen_string_literal: true

require "digest"

module Messaging
  # Recipient-owned transactional inbox state. Notification rows contain only
  # an allowlisted projection; delivery attempts and provider state live on
  # Messaging::NotificationDelivery instead.
  class Notification < Messaging::ApplicationRecord
    self.table_name = "messaging_notifications"

    CATEGORIES = %w[transactional security credential legal].freeze
    SOURCE_TYPES = %w[
      Orders::Order Orders::Payment Orders::Refund Ticketing::Ticket
      Ticketing::TicketTransfer Ticketing::Registration
      Ticketing::RegistrationConsentRequirement Events::Event
    ].freeze

    belongs_to :user, class_name: "Core::User", inverse_of: :notifications
    belongs_to :retention_policy,
               class_name: "Core::DataRetentionPolicy",
               inverse_of: false
    belongs_to :source, polymorphic: true, optional: true
    has_many :deliveries,
             class_name: "Messaging::NotificationDelivery",
             inverse_of: :notification,
             dependent: :destroy

    before_validation :normalize_fields
    before_validation :set_projection_digest

    validates :user, :notification_type, :category, :dedupe_key,
              :retention_policy, :available_at, presence: true
    validates :category, inclusion: { in: CATEGORIES }
    validates :data, presence: true
    validates :source_type, inclusion: { in: SOURCE_TYPES }, allow_nil: true

    validate :data_is_an_object
    validate :retention_window_matches_policy

    scope :visible, -> { where(erased_at: nil).where("available_at <= ?", Time.current) }
    scope :unread, -> { where(read_at: nil) }
    scope :due, -> { visible }

    def read?
      read_at.present?
    end

    def erased?
      erased_at.present?
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id user_id notification_type category source_type source_id dedupe_key
        projection_digest retention_policy_id retain_until available_at read_at erased_at erasure_reason
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user deliveries retention_policy source]
    end

    private

    def normalize_fields
      self.notification_type = notification_type.to_s.strip.presence
      self.category = category.to_s.strip.downcase.presence
      self.source_type = source_type.to_s.strip.presence
      self.dedupe_key = dedupe_key.to_s.strip.presence
    end

    def set_projection_digest
      return unless new_record? || projection_digest.blank?

      self.projection_digest = Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(data || {}))
    end

    def data_is_an_object
      errors.add(:data, :invalid) unless data.is_a?(Hash)
    end

    def retention_window_matches_policy
      return if retention_policy.blank?

      if retention_policy.action == "erase_payload"
        errors.add(:retain_until, :blank) if retention_policy.retention_days.blank? || retain_until.blank?
        return if retain_until.blank?

        reference_time = created_at || Time.current
        errors.add(:retain_until, :invalid) unless retain_until > reference_time
      elsif retain_until.present?
        errors.add(:retain_until, :invalid)
      end
    end
  end
end
