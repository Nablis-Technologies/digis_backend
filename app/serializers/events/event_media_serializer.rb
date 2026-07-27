# frozen_string_literal: true

module Events
  class EventMediaSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    type :event_media

    attributes :id, :type, :position, :alt_text, :caption, :event_id,
               :created_by_id, :created_at, :updated_at, :file

    def file
      return nil unless object.file.attached?

      {
        filename: object.file.filename.to_s,
        content_type: object.file.content_type,
        byte_size: object.file.byte_size,
        url: url_for(object.file),
        thumbnail: url_for(object.file.variant(:thumbnail)),
        medium: url_for(object.file.variant(:gallery))
      }
    end
  end
end
