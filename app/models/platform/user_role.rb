module Platform
  class UserRole < Platform::ApplicationRecord
    belongs_to :user,
               class_name: "Platform::User",
               inverse_of: :user_roles
    belongs_to :role,
               class_name: "Platform::Role",
               inverse_of: :user_roles
    belongs_to :assigned_by,
               class_name: "Platform::User",
               optional: true,
               inverse_of: :assigned_user_roles

    validates :user_id, uniqueness: { scope: :role_id }

    scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at IS NOT NULL AND expires_at <= ?", Time.current) }

    after_commit :clear_user_cache!

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def active?
      !expired?
    end

    private

    def clear_user_cache!
      user&.clear_permission_cache!
    end
  end
end
