# frozen_string_literal: true

module Messaging
  # Recipient-only policy for notification inbox rows. Even platform admins
  # are limited to their own notifications; there is no operational read-all
  # surface through this controller.
  class NotificationPolicy < Core::ApplicationPolicy
    FIELDS = %i[id notification_type category data read_at available_at created_at].freeze
    DELIVERY_FIELDS = %i[channel status sent_at delivered_at failed_at failure_code].freeze

    def index? = user.present?
    def show? = owner?
    def read? = owner?

    VISIBILITY = {
      index: {
        default: { fields: FIELDS, include: [ :deliveries ], association_fields: { deliveries: { fields: DELIVERY_FIELDS } } },
        admin: { fields: FIELDS, include: [ :deliveries ], association_fields: { deliveries: { fields: DELIVERY_FIELDS } } }
      },
      show: {
        default: { fields: FIELDS, include: [ :deliveries ], association_fields: { deliveries: { fields: DELIVERY_FIELDS } } },
        admin: { fields: FIELDS, include: [ :deliveries ], association_fields: { deliveries: { fields: DELIVERY_FIELDS } } }
      },
      read: {
        default: { fields: FIELDS, include: [ :deliveries ], association_fields: { deliveries: { fields: DELIVERY_FIELDS } } },
        admin: { fields: FIELDS, include: [ :deliveries ], association_fields: { deliveries: { fields: DELIVERY_FIELDS } } }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        scope.where(user_id: user.id)
      end
    end

    private

    def owner?
      user.present? && record.user_id == user.id
    end
  end
end
