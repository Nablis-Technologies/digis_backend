# frozen_string_literal: true

module Catalog
  module Public
    # Attendee-safe product fields for published public events.
    class EventProductSerializer < ActiveModel::Serializer
      attributes :id, :event_id, :name, :description, :type,
                 :allow_custom_price, :sales_start_at, :sales_end_at,
                 :min_per_order, :max_per_order,
                 :schedule_change_refund_policy, :sort_order

      belongs_to :ticket_type, serializer: Catalog::Public::TicketTypeSerializer, optional: true
    end
  end
end
