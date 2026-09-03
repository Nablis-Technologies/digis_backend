# frozen_string_literal: true

module Messaging
  # Resolves notification sources to the retention scopes that can block
  # erasure. Grouping source lookups by type keeps the purge job independent of
  # polymorphic association N+1 queries while preserving explicit scope IDs.
  class RetentionScopeResolver
    def self.call(notification_ids:)
      new(notification_ids:).call
    end

    def initialize(notification_ids:)
      @notification_ids = Array(notification_ids).compact
    end

    def call
      return {} if @notification_ids.empty?

      rows = Notification.where(id: @notification_ids).pluck(:id, :user_id, :source_type, :source_id)
      scopes = rows.to_h do |id, user_id, source_type, source_id|
        [ id, { user_ids: [ user_id ], event_ids: [], registration_ids: [] }.tap do |scope|
          scope[:event_ids] << source_id if source_type == "Events::Event"
          scope[:registration_ids] << source_id if source_type == "Ticketing::Registration"
        end ]
      end

      add_registration_scopes!(scopes, rows)
      add_requirement_scopes!(scopes, rows)
      add_ticket_scopes!(scopes, rows)
      add_transfer_scopes!(scopes, rows)
      add_order_scopes!(scopes, rows)
      add_payment_scopes!(scopes, rows)
      add_refund_scopes!(scopes, rows)
      scopes.each_value { |scope| scope.each_value(&:uniq!) }
    end

    private

    def add_registration_scopes!(scopes, rows)
      resolve_source!(scopes, rows, "Ticketing::Registration", Ticketing::Registration, :event_id) do |scope, source_id, event_id|
        scope[:registration_ids] << source_id
        scope[:event_ids] << event_id
      end
    end

    def add_requirement_scopes!(scopes, rows)
      refs_by_source_id = source_refs_for(rows, "Ticketing::RegistrationConsentRequirement").group_by(&:last)
      return if refs_by_source_id.empty?

      registration_ids = Ticketing::RegistrationConsentRequirement.where(id: refs_by_source_id.keys)
        .pluck(:id, :registration_id)
      registrations = Ticketing::Registration.where(id: registration_ids.map(&:last)).pluck(:id, :event_id).to_h
      registration_ids.each do |source_id, registration_id|
        refs_by_source_id.fetch(source_id).each do |notification_id, _requirement_id|
          apply_scope!(scopes.fetch(notification_id), registration_id, registrations[registration_id])
        end
      end
    end

    def add_ticket_scopes!(scopes, rows)
      resolve_source!(scopes, rows, "Ticketing::Ticket", Ticketing::Ticket, :event_id, :registration_id) do |scope, _source_id, event_id, registration_id|
        apply_scope!(scope, registration_id, event_id)
      end
    end

    def add_transfer_scopes!(scopes, rows)
      relation = Ticketing::TicketTransfer.joins(:ticket)
      resolve_source!(
        scopes, rows, "Ticketing::TicketTransfer", relation,
        "ticketing_ticket_transfers.id", "ticketing_tickets.event_id", "ticketing_tickets.registration_id"
      ) do |scope, _source_id, event_id, registration_id|
        apply_scope!(scope, registration_id, event_id)
      end
    end

    def add_order_scopes!(scopes, rows)
      resolve_source!(scopes, rows, "Orders::Order", Orders::Order, :event_id) do |scope, _source_id, event_id|
        scope[:event_ids] << event_id
      end
    end

    def add_payment_scopes!(scopes, rows)
      relation = Orders::Payment.joins(:order)
      resolve_source!(scopes, rows, "Orders::Payment", relation, "orders_payments.id", "orders_orders.event_id") do |scope, _source_id, event_id|
        scope[:event_ids] << event_id
      end
    end

    def add_refund_scopes!(scopes, rows)
      relation = Orders::Refund.joins(payment: :order)
      resolve_source!(scopes, rows, "Orders::Refund", relation, "orders_refunds.id", "orders_orders.event_id") do |scope, _source_id, event_id|
        scope[:event_ids] << event_id
      end
    end

    def resolve_source!(scopes, rows, source_type, relation, *columns)
      refs_by_source_id = source_refs_for(rows, source_type).group_by(&:last)
      return if refs_by_source_id.empty?

      primary_id = relation.arel_table[:id]
      relation.where(id: refs_by_source_id.keys).pluck(primary_id, *columns).each do |source_id, *values|
        refs_by_source_id.fetch(source_id).each do |notification_id, _source_id|
          yield scopes.fetch(notification_id), source_id, *values
        end
      end
    end

    def apply_scope!(scope, registration_id, event_id)
      scope[:registration_ids] << registration_id if registration_id
      scope[:event_ids] << event_id if event_id
    end

    def source_refs_for(rows, source_type)
      rows.filter_map do |notification_id, _user_id, type, source_id|
        [ notification_id, source_id ] if type == source_type && source_id
      end
    end
  end
end
