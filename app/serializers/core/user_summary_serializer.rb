# frozen_string_literal: true

module Core
  class UserSummarySerializer < ActiveModel::Serializer
    attributes :id, :email, :phone
  end
end
