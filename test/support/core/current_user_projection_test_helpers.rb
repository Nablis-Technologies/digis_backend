# frozen_string_literal: true

module Core
  module CurrentUserProjectionTestHelpers
    def with_strict_current_user_projection
      models = [
        Core::User,
        Core::UserProfile,
        Core::Role,
        Core::Permission,
        ActiveStorage::Attachment,
        ActiveStorage::Blob
      ]
      previous_values = models.to_h { |model| [ model, model.strict_loading_by_default ] }
      models.each { |model| model.strict_loading_by_default = true }
      yield
    ensure
      previous_values&.each do |model, value|
        model.strict_loading_by_default = value
      end
    end
  end
end
