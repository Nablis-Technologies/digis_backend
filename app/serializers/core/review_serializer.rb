module Core
  class ReviewSerializer < ActiveModel::Serializer
    attributes :id, :context, :status, :feedback, :reviewed_at, :created_at, :updated_at
    attribute :reviewed_by

    def reviewed_by
      return nil unless object.reviewed_by

      {
        id: object.reviewed_by.id,
        type: object.reviewed_by_type
      }
    end
  end
end
