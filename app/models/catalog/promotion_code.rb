# frozen_string_literal: true

module Catalog
  # A campaign code for a promotion. Plaintext is encrypted at rest and looked
  # up through an event-namespaced keyed digest.
  class PromotionCode < Catalog::ApplicationRecord
    self.table_name = "catalog_promotion_codes"

    belongs_to :promotion, class_name: "Catalog::Promotion", inverse_of: :promotion_codes

    encrypts :code_ciphertext

    validates :promotion, presence: true
    validates :code_ciphertext,
              presence: {
                message: ->(*_args) { I18n.t("catalog.promotion_code.errors.blank") }
              }
    validates :code_digest,
              presence: true,
              uniqueness: {
                message: ->(*_args) { I18n.t("catalog.promotion_code.errors.duplicate") }
              },
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :redemption_limit,
              numericality: {
                only_integer: true,
                greater_than: 0,
                message: ->(*_args) { I18n.t("catalog.promotion_code.errors.invalid_redemption_limit") }
              },
              allow_nil: true
    validate :window_order

    scope :active, -> { where(active: true) }
    scope :usable_at, lambda { |at|
      active
        .where("starts_at IS NULL OR starts_at <= ?", at)
        .where("ends_at IS NULL OR ends_at > ?", at)
    }

    def self.normalize_code(value)
      value.to_s.strip.upcase
    end

    def self.code_digest_for(event_id:, code:)
      Core::KeyedDigest.digest(namespace: event_id, value: normalize_code(code))
    end

    def code
      code_ciphertext
    end

    def code=(value)
      self.code_ciphertext = self.class.normalize_code(value)
    end

    def usable_at?(at)
      active? && (starts_at.blank? || starts_at <= at) && (ends_at.blank? || ends_at > at)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id promotion_id label redemption_limit starts_at ends_at active
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[promotion]
    end

    private

    def window_order
      return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

      errors.add(:ends_at, I18n.t("catalog.promotion_code.errors.invalid_window"))
    end
  end
end
