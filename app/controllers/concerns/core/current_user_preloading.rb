# frozen_string_literal: true

module Core
  module CurrentUserPreloading
    extend ActiveSupport::Concern

    private

    def preload_current_user(user)
      return user unless user.is_a?(Core::User)

      ActiveRecord::Associations::Preloader.new(
        records: [ user ],
        associations: [
          { roles: :permissions },
          { profile: { avatar_attachment: :blob } }
        ]
      ).call
      user
    end
  end
end
