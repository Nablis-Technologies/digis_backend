# frozen_string_literal: true

module Messaging
  # Exposes only the current user's inbox; platform administrators do not get a
  # read-all bypass because notification payloads are recipient-owned by design.
  class NotificationsController < Messaging::ApplicationController
    before_action :set_notification, only: %i[show read]

    def index
      @clazz = Messaging::Notification
      authorize @clazz.new(user: current_user), :index?
      notifications = policy_scope(@clazz)
        .visible
        .includes(eager_loaded_associations)
      notifications = filter_records(notifications)
      notifications = apply_ordering(notifications)
      total_count = notifications.count if paginated_request?
      notifications = paginated_request? ? apply_pagination(notifications) : notifications.limit(default_per_page)

      render_success(
        :"messaging.notifications.success.index",
        data: notifications,
        serializer_options: { serializer: Messaging::NotificationSerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    def show
      authorize @notification
      render_success(
        :"messaging.notifications.success.show",
        data: @notification,
        serializer_options: { serializer: Messaging::NotificationSerializer }
      )
    end

    def read
      authorize @notification, :read?
      result = Messaging::MarkNotificationRead.call(notification: @notification, user: current_user)
      return render_error(result.error.message, status: result.error.status_code, code: result.error.code) if result.failure?

      render_success(
        :"messaging.notifications.success.read",
        data: result.value,
        serializer_options: { serializer: Messaging::NotificationSerializer }
      )
    end

    private

    def set_notification
      @clazz = Messaging::Notification
      @notification = policy_scope(@clazz).includes(eager_loaded_associations).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_error(
        I18n.t("messaging.errors.notification_not_found"),
        status: :not_found,
        code: "notification_not_found"
      )
    end

    def model_params
      params.permit(:read_at)
    end

    def eager_load_config
      {
        index: [ :deliveries ],
        show: [ :deliveries ],
        read: [ :deliveries ],
        default: []
      }
    end

    def eager_loaded_associations
      config = eager_load_config
      config.fetch(action_name.to_sym, config.fetch(:default))
    end

    def allowed_order_columns
      %w[id notification_type category available_at read_at created_at]
    end

    def serializer_profile
      fields = %i[id notification_type category data read_at available_at created_at]
      delivery_fields = %i[channel status sent_at delivered_at failed_at failure_code]
      visibility = { fields:, include: [ :deliveries ], association_fields: {
        deliveries: { fields: delivery_fields }
      } }
      { index: visibility, show: visibility, read: visibility }
    end
  end
end
