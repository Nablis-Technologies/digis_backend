# frozen_string_literal: true

module Events
  class EventSettingSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :created_at, :updated_at

    attribute :config, key: :config do
      object.config
    end
  end
end
