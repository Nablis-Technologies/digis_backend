# frozen_string_literal: true

module Events
  module Public
    class EventDetailSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at, :created_at

      has_many :categories, serializer: Events::CategorySerializer
    end
  end
end
