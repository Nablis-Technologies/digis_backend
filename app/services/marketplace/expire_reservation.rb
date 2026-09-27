# frozen_string_literal: true

module Marketplace
  # Closes a failed resale checkout and restores the seller atomically. The
  # listing lock is shared with FulfillSale, so expiry and accepted-payment
  # fulfillment resolve to one terminal outcome rather than both mutating the
  # ticket. Orders remains responsible for releasing checkout reservations and
  # publishing the standard late-payment boundary.
  class ExpireReservation < Core::BaseService
    RELEASE_REASON = "checkout_expired"

    def initialize(listing:, at: Time.current)
      @listing = listing
      @now = at.to_time.utc.change(usec: 0)
    end

    def call
      ticket_type_id = ResaleListing.where(id: @listing.id).pick(:ticket_type_id)
      return failure(error(:reservation_record_not_found, :not_found)) unless ticket_type_id
      reservation_identity = reserved_checkout_identity
      return failure(error(:reservation_record_not_found, :not_found)) if
        reservation_identity && reservation_identity[:buyer_user_id].blank?

      outcome = nil
      ActiveRecord::Base.transaction do
        locked_ticket_type = Ticketing::TicketType.lock.find(ticket_type_id)
        if reservation_identity
          Orders::CheckoutLock.acquire!(
            buyer_user_id: reservation_identity.fetch(:buyer_user_id),
            event_id: reservation_identity.fetch(:event_id)
          )
        end
        listing = ResaleListing.lock.find(@listing.id)
        abort_with(error(:reservation_not_open, :conflict)) unless listing.ticket_type_id == locked_ticket_type.id
        if listing.status.in?(%w[active expired cancelled sold]) && listing.reserved_order_id.nil?
          outcome = success(listing)
          next
        end
        abort_with(error(:reservation_not_open, :conflict)) unless listing.status == "reserved"
        abort_with(error(:reservation_not_open, :conflict)) unless
          listing.reserved_order_id == reservation_identity&.fetch(:order_id)

        order = Orders::Order.lock.find(listing.reserved_order_id)
        current_payments = order.payments.where(superseded_at: nil).lock.order(:id).to_a
        current_payment = current_payments.last
        if order.paid? || current_payment&.accepted?
          outcome = failure(error(:reservation_payment_accepted, :conflict))
          next
        end

        release = release_order!(order)
        abort_with(release.error) if release.failure?

        restored = RestoreSellerAccess.call(listing:, at: now)
        abort_with(restored.error) if restored.failure?

        ticket = load_ticket(listing)
        # The first resale order item is immutable and uniquely references the
        # listing. Expiry is therefore terminal for this listing; a seller who
        # wants to try again creates a fresh listing after access is restored.
        close_listing!(listing)
        record_lifecycle!(listing, ticket)
        publish_lifecycle!(listing, ticket)
        outcome = success(listing.reload)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(error(:reservation_record_not_found, :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:reservation_invalid, :conflict, errors: exception.record.errors.to_hash))
    rescue Abort => exception
      failure(exception.business_error)
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :now

    def reserved_checkout_identity
      order_id = ResaleListing.where(id: @listing.id, status: "reserved").pick(:reserved_order_id)
      return unless order_id

      identity = Orders::Order.where(id: order_id).pick(:buyer_user_id, :event_id)
      {
        order_id:,
        buyer_user_id: identity&.first,
        event_id: identity&.last
      }
    end

    def release_order!(order)
      return success(order) if order.status == "expired"
      return failure(error(:reservation_not_releasable, :conflict)) unless order.status.in?(%w[draft pending_payment])

      Orders::ReleaseCheckout.call_locked(
        order:, reason: RELEASE_REASON, at: now, payment_rows_locked: true
      )
    end

    def load_ticket(listing)
      Ticketing::Ticket.includes(
        :revocation,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).lock.find(listing.ticket_id)
    end

    def close_listing!(listing)
      listing.update!(
        status: "expired",
        reserved_order: nil,
        reserved_at: nil,
        reservation_expires_at: nil,
        activated_at: nil,
        closed_at: now
      )
    end

    def record_lifecycle!(listing, ticket)
      result = Core::Audit::Record.call(
        audit_key: "marketplace-resale-listing-expired-#{listing.id}",
        action: "marketplace.resale_listing.expired",
        auditable_type: listing.class.name,
        auditable_id: listing.id,
        actor_type: nil,
        actor_id: nil,
        audited_changes: { status: [ "reserved", "expired" ] },
        metadata: { event_id: listing.event_id, ticket_id: ticket.id, reason: RELEASE_REASON }
      )
      abort_with(result.error) if result.failure?
    end

    def publish_lifecycle!(listing, ticket)
      result = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_listing.expired",
        aggregate: listing,
        payload: {
          listing_id: listing.id,
          event_id: listing.event_id,
          ticket_id: ticket.id,
          status: "expired",
          reason: RELEASE_REASON
        },
        idempotency_key: "marketplace-resale-listing-expired-#{listing.id}"
      )
      abort_with(result.error) if result.failure?
    end

    def abort_with(business_error)
      raise Abort, business_error
    end

    def error(code, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"),
        code:,
        status:,
        errors:
      )
    end

    class Abort < Core::Error
      attr_reader :business_error

      def initialize(error)
        @business_error = error
        super(error.message)
      end
    end
  end
end
