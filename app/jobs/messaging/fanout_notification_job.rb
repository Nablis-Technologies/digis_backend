# frozen_string_literal: true

module Messaging
  # Delivers one schedule-change notification page without holding the outbox
  # claim. Audience discovery is query-based and recipient IDs are deduplicated
  # before publishing, so collaborators and attendees receive one inbox row.
  class FanoutNotificationJob < ApplicationJob
    queue_as :notifications

    PAGE_SIZE = 100
    BOUNDED_ID_COLUMNS = %i[user_id owner_user_id].freeze

    def perform(outbox_event_id, after_user_id: nil)
      outbox_event = Core::OutboxEvent.find(outbox_event_id)
      event = load_event(outbox_event)
      date_ids = Array(outbox_event.payload.fetch("event_date_ids", [])).compact
      recipient_ids = audience_user_ids(event, date_ids, after_user_id)
      page = recipient_ids.first(PAGE_SIZE)
      publish_page(event, date_ids, outbox_event.payload, page)
      enqueue_next_page(outbox_event_id, page.last) if recipient_ids.length > page.length
    end

    private

    def load_event(outbox_event)
      Events::Event.includes(:organization, :event_organizations).find(
        outbox_event.payload.fetch("event_id")
      )
    end

    def audience_user_ids(event, date_ids, after_user_id)
      organization_ids = [ event.organization_id ] + Events::EventOrganization
        .where(event_id: event.id, status: "active")
        .pluck(:organization_id)
      admin_scope = Organizations::Membership
        .where(organization_id: organization_ids, status: "active", role: %w[owner admin])
      admin_ids = bounded_ids(admin_scope, column: :user_id, after_user_id:)
      ticket_scope = Ticketing::Ticket
        .joins(event_product: :product_accesses)
        .where(event_id: event.id, status: "active", catalog_product_accesses: { event_date_id: date_ids })
        .distinct
      ticket_holder_ids = bounded_ids(ticket_scope, column: :owner_user_id, after_user_id:)
      registration_ids = registration_user_ids(event, date_ids, after_user_id)

      merge_recipient_ids(admin_ids, ticket_holder_ids, registration_ids)
    end

    def registration_user_ids(event, date_ids, after_user_id)
      current = Ticketing::Registration
        .where(event_id: event.id, status: Ticketing::Registration::STATUSES & %w[
          pending_payment pending_approval waitlisted offered confirmed
        ])
      selected_ids = bounded_ids(
        current.where(selected_event_date_id: date_ids), column: :user_id, after_user_id:
      )
      fixed_scope = current
        .where(selected_event_date_id: nil)
        .joins(ticket_type: { event_product: :product_accesses })
        .where(
          ticketing_ticket_types: { date_selection: "fixed" },
          catalog_product_accesses: { event_date_id: date_ids }
        )
        .distinct
      fixed_ids = bounded_ids(fixed_scope, column: :user_id, after_user_id:)
      selected_ids + fixed_ids
    end

    def bounded_ids(scope, column:, after_user_id:)
      if after_user_id.present?
        raise ArgumentError unless BOUNDED_ID_COLUMNS.include?(column.to_sym)

        scope = scope.where(scope.klass.arel_table[column].gt(after_user_id.to_s))
      end
      scope.distinct.order(column).limit(PAGE_SIZE + 1).pluck(column)
    end

    def merge_recipient_ids(*sources)
      sources.flatten.compact.uniq.sort
    end

    def publish_page(event, date_ids, payload, user_ids)
      definition = NotificationTypes.fetch("schedule_changed")
      data = {
        "event_id" => event.id,
        "schedule_version" => payload.fetch("version", event.schedule_version),
        "event_date_ids" => date_ids
      }
      users = Core::User.where(id: user_ids).index_by(&:id)
      failures = user_ids.filter_map do |user_id|
        user = users[user_id]
        next unless user

        result = PublishNotification.call(
          type: "schedule_changed",
          recipient: user,
          source: event,
          data:,
          dedupe_key: definition.dedupe_key_for(source: event, recipient: user, payload: data)
        )
        result.failure? ? result.error.code : nil
      end
      Rails.logger.warn("Messaging schedule fan-out failures: #{failures.tally.inspect}") if failures.any?
    end

    def enqueue_next_page(outbox_event_id, after_user_id)
      self.class.perform_later(outbox_event_id, after_user_id:)
    end
  end
end
