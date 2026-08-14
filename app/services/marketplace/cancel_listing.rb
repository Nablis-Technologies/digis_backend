# frozen_string_literal: true

module Marketplace
  # Closes an unsold resale offer without touching the ticket credential. A
  # cancelled listing is terminal, so repeated policy or seller cleanup calls
  # return the same row and never emit a second lifecycle event.
  class CancelListing < Core::BaseService
    CANCELLATION_REASONS = %w[resale_policy_disabled seller_requested].freeze

    def initialize(listing:, idempotency_key:, reason:)
      @listing = listing
      @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      @reason = reason.to_s.strip.downcase
    rescue ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(error(:invalid_idempotency_key, :unprocessable_entity)) if @initialization_error
      return failure(error(:cancellation_reason_invalid, :unprocessable_entity)) unless CANCELLATION_REASONS.include?(@reason)

      outcome = nil
      ResaleListing.transaction do
        listing = ResaleListing.lock.find(@listing.id)
        if listing.status == "cancelled"
          outcome = success(listing)
          next
        end
        unless listing.open?
          outcome = failure(error(:listing_not_open, :conflict))
          next
        end

        listing.update!(
          status: "cancelled",
          reserved_order: nil,
          reserved_at: nil,
          reservation_expires_at: nil,
          activated_at: nil,
          closed_at: Time.current
        )
        record_cancellation!(listing)
        publish_cancellation!(listing)
        outcome = success(listing)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(error(:listing_not_found, :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:listing_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :listing, :idempotency_key, :reason

    def record_cancellation!(cancelled_listing)
      audit = Core::Audit::Record.call(
        audit_key: "marketplace-resale-listing-cancelled-#{cancelled_listing.id}",
        action: "marketplace.resale_listing.cancelled",
        auditable_type: cancelled_listing.class.name,
        auditable_id: cancelled_listing.id,
        audited_changes: { status: "cancelled" },
        metadata: { event_id: cancelled_listing.event_id, ticket_id: cancelled_listing.ticket_id, reason: }
      )
      raise audit.error if audit.failure?
    end

    def publish_cancellation!(cancelled_listing)
      outbox = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_listing.cancelled",
        aggregate: cancelled_listing,
        payload: {
          listing_id: cancelled_listing.id,
          event_id: cancelled_listing.event_id,
          ticket_id: cancelled_listing.ticket_id,
          reason:
        },
        idempotency_key: "marketplace-resale-listing-cancelled-#{cancelled_listing.id}"
      )
      raise outbox.error if outbox.failure?
    end

    def error(code, status, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"),
        code:,
        status:,
        errors:
      )
    end
  end
end
