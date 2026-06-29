module Core
  module Followable
    extend ActiveSupport::Concern

    included do
      has_many :follows, as: :followable, class_name: "Core::Follow", dependent: :destroy
      has_many :followers, through: :follows, source: :follower
    end

    def followed_by?(user)
      return false unless user&.id
      if follows.loaded?
        follows.any? { |f| f.follower_id == user.id }
      else
        follows.exists?(follower_id: user.id)
      end
    end
  end
end
