# frozen_string_literal: true

module Events
  module Public
    # Minimal venue projection for public event schedules.
    class VenueSummarySerializer < ActiveModel::Serializer
      attributes :id, :name, :city
    end
  end
end
