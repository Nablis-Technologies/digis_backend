# frozen_string_literal: true

module Events
  module Organizer
    # Limits organizer event responses to the setting the editor owns; other
    # JSONB configuration remains internal to its feature.
    class EventSettingSerializer < ActiveModel::Serializer
      attributes :id, :config

      def config
        age_restriction = object.safe_age_restriction
        age_restriction ? { "age_restriction" => age_restriction } : {}
      end
    end
  end
end
