class Core::FollowSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :id, :followable_type, :followable_id, :followed_at, :created_at

  attribute :follower do
    Core::Public::UserSerializer.new(object.follower).as_json
  end

  attribute :followable do
    { type: object.followable_type, id: object.followable_id }
  end
end
