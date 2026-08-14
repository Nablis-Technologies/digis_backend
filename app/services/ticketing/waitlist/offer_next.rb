# frozen_string_literal: true

require "securerandom"

  module Ticketing
    module Waitlist
      # Promotes the oldest complete party that fits under the inventory lock.
      # Each offer receives its own reservation group so an expired offer can be
      # requeued and offered again without colliding with released history.
      class OfferNext < Core::BaseService
      include Support

      def initialize(ticket_type:, idempotency_key:, offer_duration: 10.minutes, selected_event_date_id: nil)
        @ticket_type = ticket_type
        @idempotency_key = idempotency_key
        @offer_duration = offer_duration
        @selected_event_date_id = selected_event_date_id
      end

      def call
        Core::IdempotencyKey.new(idempotency_key)
        offered = Ticketing::Registration.transaction do
          event_id = Ticketing::TicketType.joins(:event_product).where(id: @ticket_type.id).pick(:event_id)
          event = Events::Event.lock.find(event_id)
          halt(waitlist_error("event_cancelled")) if event.status == "cancelled"
          ticket_type = Ticketing::TicketType.lock
            .includes(event_product: :inventories)
            .find(@ticket_type.id)
          halt(waitlist_error("waitlist_disabled")) unless ticket_type.waitlist_enabled?

          product = ticket_type.event_product
          selected_event_date_id = @selected_event_date_id
          inventory_scope = Ticketing::Registration.new(
            ticket_type:, selected_event_date_id:
          )
          inventories = lock_product_inventories(product, inventory_scope)
          excluded_ids = []

          loop do
            candidate = candidate_scope(ticket_type, selected_event_date_id, excluded_ids).first
            break unless candidate

            excluded_ids << candidate.id
            candidate.association(:ticket_type).target = ticket_type
            candidate.association(:event).target = ticket_type.event
            next unless inventory_fits?(product, candidate, inventories)

            group_id = SecureRandom.uuid
            expiry = Time.current + @offer_duration
            reserved = reserve_capacity!(
              candidate,
              idempotency_key: "ticketing-waitlist-offer-#{group_id}",
              expires_at: expiry,
              reservation_group_id: group_id
            )
            next if reserved.failure?

            now = Time.current
            candidate.update!(
              status: "offered",
              waitlisted_at: nil,
              offered_at: now,
              offer_expires_at: expiry,
              next_action_snapshot: free_product?(candidate) ? "requires_confirmation" : "requires_order"
            )
            unwrap(Core::Outbox::Publish.call(
              topic: "ticketing",
              event_type: "ticketing.registration.waitlist_offer_created",
              aggregate: candidate,
              payload: { registration_id: candidate.id, offer_expires_at: expiry.iso8601 },
              idempotency_key: "ticketing-registration-waitlist-offer-#{group_id}"
            ))
            break candidate
          end
        end

        success(offered)
      rescue Ticketing::Registrations::Support::Halt => error
        error.result
      rescue ArgumentError
        failure(waitlist_error("invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::BusinessError.new(
          I18n.t("ticketing.registration_workflows.errors.invalid_registration"),
          code: "invalid_registration", status: :unprocessable_entity, errors: error.record.errors.to_hash
        ))
      end

      private

      attr_reader :ticket_type, :idempotency_key, :selected_event_date_id

      def halt(error)
        fail Ticketing::Registrations::Support::Halt, Core::BaseService::Result.failure(error)
      end
      end
    end
  end
