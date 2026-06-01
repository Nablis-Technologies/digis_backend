module Organizations
  module Public
    class OrganizationListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      include Rails.application.routes.url_helpers

      attributes :id, :name, :slug, :description, :created_at

      attribute :profile_url do
        object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [ 300, 300 ])) : nil
      end
    end
  end
end
