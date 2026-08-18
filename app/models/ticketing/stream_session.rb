# frozen_string_literal: true

module Ticketing
  # Short-lived online authorization for live or replay playback. The session
  # stores only a digest of the Digis token; ticket ownership and event/stream
  # scope remain authoritative database relationships.
  class StreamSession < Ticketing::ApplicationRecord
    self.table_name = "ticketing_stream_sessions"

    STATUSES = %w[active expired revoked].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :stream_sessions
    belongs_to :event_stream, class_name: "Events::EventStream", inverse_of: :stream_sessions
    belongs_to :user, class_name: "Core::User", inverse_of: :stream_sessions

    before_validation :normalize_fields

    validates :ticket, :event_stream, :user, :device_id, :session_token_digest,
              :status, :expires_at, presence: true
    validates :device_id, length: { maximum: 255 }
    validates :session_token_digest,
              format: { with: /\A[0-9a-f]{64}\z/ },
              uniqueness: true
    validates :status, inclusion: { in: STATUSES }
    validate :expires_after_creation
    validate :revocation_timestamp_matches_status

    scope :active, -> { where(status: "active").where("expires_at > ?", Time.current) }

    def active?
      status == "active" && expires_at.present? && expires_at > Time.current
    end

    def expired?
      status == "expired" || (expires_at.present? && expires_at <= Time.current)
    end

    def revoked?
      status == "revoked"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id ticket_id event_stream_id user_id device_id status expires_at last_seen_at revoked_at
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket event_stream user]
    end

    private

    def normalize_fields
      self.device_id = device_id.to_s.strip.presence
      self.session_token_digest = session_token_digest.to_s.strip.downcase.presence
      self.status = status.to_s.strip.downcase.presence
    end

    def expires_after_creation
      return if expires_at.blank? || created_at.blank?
      return if expires_at > created_at

      errors.add(:expires_at, :invalid)
    end

    def revocation_timestamp_matches_status
      if status == "revoked"
        errors.add(:revoked_at, :blank) if revoked_at.blank?
      elsif revoked_at.present?
        errors.add(:revoked_at, :invalid)
      end
    end
  end
end
