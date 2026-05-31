module Core
  class Follow < Core::ApplicationRecord
    belongs_to :follower, class_name: "Core::User"
    belongs_to :followable, polymorphic: true, counter_cache: :followers_count

    before_validation { self.followed_at ||= Time.current }

    validates :follower_id, uniqueness: { scope: [ :followable_id, :followable_type ] }

    scope :for_type, ->(type) { where(followable_type: type) }
  end
end
