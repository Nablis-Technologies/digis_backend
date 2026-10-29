# frozen_string_literal: true

module Events
  module Public
    # Public media contains safe resized variants only; original storage URLs
    # and attachment metadata remain private.
    class EventMediaSerializer < ActiveModel::Serializer
      include Rails.application.routes.url_helpers

      attributes :id, :type, :position, :alt_text, :caption, :file

      def file
        return nil unless object.file.attached?

        {
          thumbnail: url_for(object.file.variant(:thumbnail)),
          medium: url_for(object.file.variant(:gallery))
        }
      end
    end
  end
end
