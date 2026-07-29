# frozen_string_literal: true

module Catalog
  # Serializes the full product record, along with the associated event and
  # (for ticket products) the ticket type.
  class EventProductSerializer < ActiveModel::Serializer
    attributes :id, :event_id, :name, :description, :type, :status, :inventory_mode,
               :allow_custom_price, :sales_start_at, :sales_end_at, :min_per_order,
               :max_per_order, :schedule_change_refund_policy, :sort_order, :metadata,
               :lock_version, :created_at, :updated_at

    belongs_to :event, serializer: Events::EventSerializer
    belongs_to :ticket_type, serializer: Ticketing::TicketTypeSerializer, optional: true
  end
end
