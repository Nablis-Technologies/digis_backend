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

    scope :active, -> {
      table = Platform::UserRole.arel_table
      where(table[:expires_at].eq(nil).or(table[:expires_at].gt(Time.current)))
    }
    scope :expired, -> {
      table = Platform::UserRole.arel_table
      where(table[:expires_at].not_eq(nil).and(table[:expires_at].lteq(Time.current)))
    }

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
