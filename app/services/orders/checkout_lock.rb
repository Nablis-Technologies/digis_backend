# frozen_string_literal: true

module Orders
  # Acquires the shared transaction lock that serializes checkout mutations
  # for one buyer and event.
  class CheckoutLock
    SCOPE = "orders-checkout".freeze

    def self.acquire!(buyer_user_id:, event_id:)
      Core::Database::AdvisoryLock.acquire!(SCOPE, buyer_user_id, event_id)
    end

    def self.acquire_for_order!(order_id:, ticket_type_ids: nil)
      buyer_user_id, event_id, sales_channel = Orders::Order.where(id: order_id)
        .pick(:buyer_user_id, :event_id, :sales_channel)
      raise ActiveRecord::RecordNotFound unless buyer_user_id && event_id

      type_ids = Array(ticket_type_ids).compact.uniq
      if type_ids.empty? && sales_channel == "resale"
        type_ids = Orders::OrderItem.joins(:registration).where(order_id:)
          .distinct.pluck("ticketing_registrations.ticket_type_id").compact.uniq
      end
      Ticketing::TicketType.where(id: type_ids).order(:id).lock.to_a if type_ids.any?

      acquire!(buyer_user_id:, event_id:)
    end

    def self.acquire_all!(buyer_event_pairs)
      lock_parts = buyer_event_pairs.map { |buyer_id, event_id| [ SCOPE, buyer_id, event_id ] }
        .uniq
        .sort_by { |parts| parts.map(&:to_s).join(":") }
      Core::Database::AdvisoryLock.acquire_all!(*lock_parts)
    end
  end
end
