# frozen_string_literal: true

module Core
  class UserPolicy < Core::ApplicationPolicy
    def show? = owns_record?
    def update? = owns_record?
    def avatar? = owns_record?
    def update_avatar? = owns_record?
    def remove_avatar? = owns_record?

    private

    def owns_record?
      user.present? && record.is_a?(Core::User) && record.id == user.id
    end
  end
end
