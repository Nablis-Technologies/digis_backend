# frozen_string_literal: true

require "uri/mailto"

module Orders
  # Private recipient details and the bearer capability for one order-item gift.
  # The order item remains the sole commercial and refund source of truth.
  class GiftPurchase < Orders::ApplicationRecord
    self.table_name = "orders_gift_purchases"

    STATUSES = %w[pending_payment ready pending_recipient_consent claimed expired revoked].freeze
    DELIVERY_STATUSES = %w[pending sent partial failed].freeze
    NOTE_MAX_LENGTH = 500

    belongs_to :order_item, class_name: "Orders::OrderItem", inverse_of: :gift_purchase
    belongs_to :recipient_user, class_name: "Core::User"

    encrypts :recipient_phone_ciphertext, :recipient_email_ciphertext, :note_ciphertext, :token_ciphertext

    validates :recipient_phone, :recipient_phone_digest, :token, :token_digest, :expires_at, presence: true
    validates :recipient_user, :order_item, presence: true
    validates :recipient_phone_digest, :token_digest, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :recipient_email_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validates :token_digest, uniqueness: true
    validates :order_item_id, uniqueness: true
    validates :recipient_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validates :note, length: { maximum: NOTE_MAX_LENGTH }, allow_blank: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :delivery_status, presence: true, inclusion: { in: DELIVERY_STATUSES }
    validates :delivery_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    validate :order_item_is_single_ticket_package
    validate :recipient_matches_registration
    validate :recipient_contact_digests_match
    validate :lifecycle_timestamps_match
    validate :delivery_timestamp_matches
    validate :expiry_is_immutable

    scope :unexpired, ->(at = Time.current) { where("expires_at > ?", at) }
    scope :due_for_expiry, ->(at = Time.current) { where(status: %w[ready pending_recipient_consent claimed]).where("expires_at <= ?", at) }

    def payer_status_payload
      {
        id:,
        status:,
        expires_at:,
        delivery_status:,
        delivered_at:,
        claimed_at:
      }
    end

    def recipient_phone
      recipient_phone_ciphertext
    end

    def recipient_phone=(value)
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(value)
      self.recipient_phone_ciphertext = normalized.present? ? "+#{normalized}" : nil
    end

    def recipient_email
      recipient_email_ciphertext
    end

    def recipient_email=(value)
      self.recipient_email_ciphertext = value.to_s.strip.downcase.presence
    end

    def note
      note_ciphertext
    end

    def note=(value)
      self.note_ciphertext = value.to_s.strip.presence
    end

    def token
      token_ciphertext
    end

    def token=(value)
      self.token_ciphertext = value.to_s.presence
    end

    def self.token_digest_for(token:)
      Core::KeyedDigest.digest(namespace: "orders-gift-purchase-token", value: token.to_s)
    end

    def self.recipient_phone_digest_for(phone:)
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(phone)
      return if normalized.blank?

      Core::KeyedDigest.digest(namespace: "orders-gift-purchase-phone", value: normalized)
    end

    def self.recipient_email_digest_for(email:)
      normalized = email.to_s.strip.downcase
      return if normalized.blank?

      Core::KeyedDigest.digest(namespace: "orders-gift-purchase-email", value: normalized)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id order_item_id recipient_user_id status delivery_status expires_at ready_at delivered_at
         claimed_at expired_at revoked_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end

    private

    def order_item_is_single_ticket_package
      return if order_item.blank?
      return if order_item.type_snapshot == "ticket" && order_item.quantity == 1

      errors.add(:order_item, :invalid)
    end

    def recipient_matches_registration
      return if order_item.blank?
      if order_item.registration_id.blank?
        errors.add(:order_item, :invalid)
        return
      end

      registration_user_id = if order_item.association(:registration).loaded?
        order_item.registration&.user_id
      else
        Ticketing::Registration.where(id: order_item.registration_id).pick(:user_id)
      end
      return if registration_user_id == recipient_user_id

      errors.add(:recipient_user, :invalid)
    end

    def recipient_contact_digests_match
      expected_phone_digest = self.class.recipient_phone_digest_for(phone: recipient_phone)
      errors.add(:recipient_phone_digest, :invalid) unless recipient_phone_digest == expected_phone_digest

      expected_email_digest = self.class.recipient_email_digest_for(email: recipient_email)
      errors.add(:recipient_email_digest, :invalid) unless recipient_email_digest == expected_email_digest

      expected_token_digest = self.class.token_digest_for(token:)
      errors.add(:token_digest, :invalid) unless token_digest == expected_token_digest
    end

    def lifecycle_timestamps_match
      if status.in?(%w[ready pending_recipient_consent claimed]) && ready_at.blank?
        errors.add(:ready_at, :blank)
      elsif status == "pending_payment" && ready_at.present?
        errors.add(:ready_at, :invalid)
      end

      if status == "claimed"
        errors.add(:claimed_at, :blank) if claimed_at.blank?
      elsif status.in?(%w[pending_payment ready pending_recipient_consent]) && claimed_at.present?
        errors.add(:claimed_at, :invalid)
      end

      errors.add(:expired_at, :blank) if status == "expired" && expired_at.blank?
      errors.add(:revoked_at, :blank) if status == "revoked" && revoked_at.blank?
      errors.add(:revoked_at, :invalid) if status == "expired" && revoked_at.present?
    end

    def delivery_timestamp_matches
      if delivery_status == "sent"
        errors.add(:delivered_at, :blank) if delivered_at.blank?
      elsif delivery_status == "pending"
        errors.add(:delivered_at, :invalid) if delivered_at.present?
      end
    end

    def expiry_is_immutable
      return unless persisted? && will_save_change_to_expires_at?

      errors.add(:expires_at, :immutable)
    end
  end
end
