# frozen_string_literal: true

module Events
  module Public
    # Public category projection without audit or organizer-only metadata.
    class CategorySerializer < ActiveModel::Serializer
      attributes :id, :name, :description, :slug
    end
  end
end
