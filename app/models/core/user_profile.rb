# frozen_string_literal: true

module Core
  class UserProfile < Core::ApplicationRecord
    THUMB_VARIANT = { resize_to_fill: [ 200, 200 ].freeze }.freeze

    belongs_to :user, class_name: "Core::User", inverse_of: :profile

    has_one_attached :avatar do |attachment|
      attachment.variant :thumb, THUMB_VARIANT
    end

    before_validation :normalize_names

    validates :user_id, uniqueness: true
    validates :first_name, :last_name, presence: true, length: { maximum: 100 }
    validate :names_are_valid_unicode_without_control_characters

    def full_name
      [ first_name, last_name ].compact.join(" ").gsub(/\p{Space}+/u, " ").strip
    end

    def self.normalize_name(value)
      text = value.to_s
      return text unless text.valid_encoding?

      text.unicode_normalize(:nfc).gsub(/\A\p{Space}+|\p{Space}+\z/u, "").presence
    rescue ArgumentError
      text
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end

    private

    def normalize_names
      self.first_name = self.class.normalize_name(first_name)
      self.last_name = self.class.normalize_name(last_name)
    end

    def names_are_valid_unicode_without_control_characters
      %i[first_name last_name].each do |attribute|
        value = public_send(attribute)
        next if value.blank?

        if !value.valid_encoding? || value.match?(/\p{Cc}/u)
          errors.add(attribute, :invalid)
        end
      end
    end
  end
end
