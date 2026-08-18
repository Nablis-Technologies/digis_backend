# frozen_string_literal: true

module Marketplace
  # Replaces the revoked seller credential set after a resale hold fails. The
  # historical generation is never reactivated: a newer group generation is
  # created first, the scanner projection is rebuilt, and the package
  # suspension is cleared only after the replacement succeeds.
  class RestoreSellerAccess < Core::BaseService
    include Ticketing::Suspensions::Support

    def initialize(listing:, at: Time.current, reason: "resale_checkout_expired")
      @listing = listing
      @now = at.to_time.utc.change(usec: 0)
      @reason = reason.to_s.presence || "resale_checkout_expired"
      @idempotency_key = "marketplace-resale-seller-restoration-#{listing.id}"
    end

    def call
      outcome = nil
      ActiveRecord::Base.transaction do
        listing = ResaleListing.lock.find(@listing.id)
        event = Events::Event.lock.find(listing.event_id)
        ticket = load_ticket(listing)
        generations = lock_generations(ticket)
        slots = Ticketing::AdmissionSlot.where(ticket_id: ticket.id).lock.order(:position).to_a
        current = generations.find { |generation| generation.id == ticket.current_credential_generation_id }

        if listing.status == "sold"
          outcome = success(current)
          next
        end

        if restored?(ticket, current)
          outcome = success(current)
          next
        end

        validate_restoration!(listing, event, ticket, current, slots)
        replacement = Ticketing::CredentialGenerations::Replace.call(
          ticket:,
          target_mode: "group",
          reason: @reason,
          assignments: {},
          idempotency_key: @idempotency_key,
          allow_suspended: true,
          allow_cutoff_passed: true
        )
        abort_with(replacement.error) if replacement.failure?

        restored_ticket = Ticketing::Ticket.lock.find(ticket.id)
        restored_event = Events::Event.lock.find(event.id)
        revocation = Ticketing::Revocation.lock.find_by!(ticket_id: restored_ticket.id)
        publish_projection!(
          ticket: restored_ticket,
          event: restored_event,
          revocation:,
          is_dead: false,
          is_suspended: false,
          revoked_through_version: current.version
        )
        generation = replacement.value
        record_restoration!(listing, restored_ticket, generation)
        publish_restoration!(listing, restored_ticket, generation, restored_event)
        outcome = success(generation.reload)
      end
      outcome
    rescue ActiveRecord::RecordNotFound
      failure(error(:seller_restore_record_not_found, :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:seller_restore_failed, :conflict, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      replay = Ticketing::CredentialGeneration.find_by(
        ticket_id: @listing.ticket_id,
        version: Ticketing::CredentialGeneration.where(ticket_id: @listing.ticket_id).maximum(:version)
      )
      return success(replay) if replay&.status == "active"

      failure(error(:seller_restore_conflict, :conflict))
    rescue Abort => exception
      failure(exception.business_error)
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :now, :reason

    def load_ticket(listing)
      Ticketing::Ticket.includes(
        :event,
        :owner_user,
        :revocation,
        current_credential_generation: :credentials,
        admission_slots: :assigned_user,
        registration: :consent_requirements,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).lock.find(listing.ticket_id)
    end

    def lock_generations(ticket)
      Ticketing::CredentialGeneration.where(ticket_id: ticket.id)
        .includes(:credentials).lock.order(:version).to_a
    end

    def restored?(ticket, generation)
      ticket.status == "active" && !ticket.package_suspended? && generation&.status == "active" &&
        generation.mode == "group" && generation.id == ticket.current_credential_generation_id &&
        generation.version == ticket.credential_version
    end

    def validate_restoration!(listing, event, ticket, generation, slots)
      abort_with(error(:seller_restore_conflict, :conflict)) if event.status.in?(%w[cancelled completed])
      abort_with(error(:seller_restore_conflict, :conflict)) unless ticket.status == "active"
      abort_with(error(:seller_restore_conflict, :conflict)) if ticket.package_dead?
      abort_with(error(:listing_seller_changed, :conflict)) unless ticket.owner_user_id == listing.seller_user_id
      abort_with(error(:package_suspension_missing, :conflict)) unless ticket.package_suspended?
      abort_with(error(:seller_restore_conflict, :conflict)) unless generation&.status == "revoked" &&
        generation.mode == "group" && generation.id == ticket.current_credential_generation_id &&
        generation.version == ticket.credential_version
      abort_with(error(:invalid_generation_slots, :conflict)) unless
        slots.map(&:position) == (1..ticket.admissions_per_unit_snapshot).to_a
      abort_with(error(:seller_restore_conflict, :conflict)) unless
        ticket.current_acquisition_product_value_minor == listing.seller_acquisition_product_value_minor &&
        ticket.current_acquisition_currency == listing.currency
    end

    def record_restoration!(listing, ticket, generation)
      result = Core::Audit::Record.call(
        audit_key: "marketplace-resale-listing-seller-restored-#{listing.id}",
        action: "marketplace.resale_listing.seller_access_restored",
        auditable_type: listing.class.name,
        auditable_id: listing.id,
        actor_type: nil,
        actor_id: nil,
        audited_changes: { credential_generation_version: generation.version },
        metadata: {
          event_id: listing.event_id,
          ticket_id: ticket.id,
          previous_generation_version: generation.version - 1,
          reason:
        }
      )
      abort_with(result.error) if result.failure?
    end

    def publish_restoration!(listing, ticket, generation, event)
      result = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_listing.seller_access_restored",
        aggregate: listing,
        payload: {
          listing_id: listing.id,
          event_id: event.id,
          ticket_id: ticket.id,
          seller_user_id: listing.seller_user_id,
          credential_version: generation.version,
          revocation_version: ticket.revocation.revocation_version,
          reason:
        },
        idempotency_key: "marketplace-resale-listing-seller-restored-#{listing.id}"
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
