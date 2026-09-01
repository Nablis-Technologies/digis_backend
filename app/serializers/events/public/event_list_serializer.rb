# frozen_string_literal: true

module Events
  module Public
    class EventListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at

      has_many :categories, serializer: Events::Public::CategorySerializer
      has_many :event_dates, serializer: Events::Public::EventDateSerializer
      has_many :event_media, serializer: Events::Public::EventMediaSerializer
      has_many :event_organizations, serializer: Events::Public::EventOrganizationSerializer
      has_one :event_setting, serializer: Events::Public::EventSettingSerializer
      has_one :organization, serializer: Events::Public::OrganizationSummarySerializer
    end
  end
end
