# frozen_string_literal: true

module Events
  module Public
    class EventListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :slug, :title, :description, :visibility,
                 :timezone, :currency, :published_at

      has_many :categories, serializer: Events::CategorySerializer
    end
  end
end
