# frozen_string_literal: true

module Events
  class EventSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :slug, :title, :description, :status, :visibility,
               :timezone, :currency, :version, :published_at, :cancelled_at,
               :created_at, :updated_at, :organization_id

    belongs_to :organization, serializer: Organizations::OrganizationSerializer
    has_one :event_setting, serializer: Events::EventSettingSerializer
    has_many :categories, serializer: Events::CategorySerializer
  end
end
