# frozen_string_literal: true

module Events
  module Public
    # Exposes only settings intentionally safe for public discovery. Private
    # access codes and organizer configuration never cross this boundary.
    class EventSettingSerializer < ActiveModel::Serializer
      PUBLIC_CONFIG_KEYS = %w[allow_waitlist public_guest_limit].freeze

      attributes :id, :config

      def config
        object.config.to_h.stringify_keys.slice(*PUBLIC_CONFIG_KEYS)
      end
    end
  end
end
