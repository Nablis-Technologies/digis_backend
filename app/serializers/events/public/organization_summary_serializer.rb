# frozen_string_literal: true

module Events
  module Public
    # Minimal organization projection used inside public event responses.
    class OrganizationSummarySerializer < ActiveModel::Serializer
      attributes :id, :name, :slug
    end
  end
end
