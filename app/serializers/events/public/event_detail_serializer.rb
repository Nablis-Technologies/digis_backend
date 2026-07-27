# frozen_string_literal: true

module Events
  module Public
    class EventDetailSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at, :created_at

      has_many :categories, serializer: Events::CategorySerializer
      has_many :event_dates, serializer: Events::EventDateSerializer
      has_many :event_media, serializer: Events::EventMediaSerializer
      has_many :event_organizations, serializer: Events::EventOrganizationSerializer
      has_many :event_streams, serializer: Events::EventStreamSerializer
    end
  end
end
