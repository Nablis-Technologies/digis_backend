# frozen_string_literal: true

module Messaging
  # Monotonically marks one recipient-owned notification as read. Repeating
  # the command is safe because it never performs an external side effect.
  class MarkNotificationRead < Core::BaseService
    def initialize(notification:, user:)
      @notification = notification
      @user = user
    end

    def call
      notification = Messaging::Notification
        .where(id: @notification.id, user_id: @user.id)
        .lock
        .first
      return failure(error(:notification_not_found, :not_found)) unless notification

      notification.update!(read_at: Time.current) unless notification.read?
      success(notification)
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:invalid_notification, :unprocessable_entity, errors: exception.record.errors.to_hash))
    end

    private

    def error(key, status, errors: nil)
      Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:)
    end
  end
end
