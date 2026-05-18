module Platform
  class User < Platform::ApplicationRecord
    include Platform::UserAuthenticatable

    has_many :user_roles,
             class_name: "Platform::UserRole",
             foreign_key: :user_id,
             dependent: :destroy,
             inverse_of: :user
    has_many :roles,
             through: :user_roles,
             class_name: "Platform::Role"

    has_many :assigned_user_roles,
             class_name: "Platform::UserRole",
             foreign_key: :assigned_by_id,
             dependent: :nullify,
             inverse_of: :assigned_by
    has_many :submitted_reviews,
             class_name: "Platform::Review",
             as: :reviewed_by,
             dependent: :nullify

    def self.ransackable_attributes(_auth_object = nil)
      %w[id email phone verified_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[roles]
    end

    def has_role?(role_code)
      active_role_codes.include?(role_code.to_s.upcase)
    end

    def has_permission?(permission_code)
      return true if super_admin?

      active_permissions.include?(permission_code.to_s)
    end

    alias can? has_permission?

    def has_all_permissions?(*permission_codes)
      permission_codes.flatten.all? { |code| has_permission?(code) }
    end

    def has_any_permission?(*permission_codes)
      permission_codes.flatten.any? { |code| has_permission?(code) }
    end

    def super_admin?
      has_role?("SUPER_ADMIN")
    end

    def active_permissions
      @active_permissions ||= Platform::Permission
        .joins(role_permissions: { role: :user_roles })
        .where(platform_user_roles: { user_id: id })
        .where(platform_roles: { active: true }, platform_permissions: { active: true })
        .where("platform_user_roles.expires_at IS NULL OR platform_user_roles.expires_at > ?", Time.current)
        .distinct
        .pluck(:code)
    end

    def active_role_codes
      @active_role_codes ||= roles
        .where(active: true)
        .joins(:user_roles)
        .where(platform_user_roles: { user_id: id })
        .where("platform_user_roles.expires_at IS NULL OR platform_user_roles.expires_at > ?", Time.current)
        .distinct
        .pluck(:code)
    end

    def clear_permission_cache!
      @active_permissions = nil
      @active_role_codes = nil
    end
  end
end
