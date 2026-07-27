# frozen_string_literal: true

module Events
  class EventVideoLinkSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_video_link

    attributes :id, :event_id, :created_by_id, :provider, :url, :title,
               :caption, :position, :created_at, :updated_at
  end
end
