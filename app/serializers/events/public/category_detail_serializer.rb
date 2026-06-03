class Events::Public::CategoryDetailSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
end
