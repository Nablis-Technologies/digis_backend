# frozen_string_literal: true

module Ticketing
  module Registrations
    # Creates an incomplete recipient registration for a paid gift. Answers,
    # consents, confirmation, and ticket issuance belong to the later claim.
    class PrepareGift < Core::BaseService
      class Abort < Core::Error
        attr_reader :result

        def initialize(result)
          @result = result
          super(result.error.message)
        end
      end

      def initialize(ticket_type:, purchaser:, recipient_phone:, package_quantity:,
        selected_event_date_id:, idempotency_key:)
        @ticket_type_id = ticket_type&.id
        @purchaser = purchaser
        @normalized_phone = Core::PhoneIdentity::ResolveOrCreate.normalize(recipient_phone)
        @package_quantity = package_quantity
        @selected_event_date_id = selected_event_date_id.presence
        @raw_idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        return failure(phone_identity_invalid) if normalized_phone.blank?
        return failure(phone_identity_invalid) unless @purchaser.is_a?(Core::User)
        return failure(error("quantity_invalid")) unless @package_quantity.to_i == 1

        outcome = nil
        Registration.transaction do
          ticket_type = load_ticket_type
          event = Events::Event.lock.find(ticket_type.event_product.event_id)
          raise Abort, failure(event_cancelled_error) if event.status == "cancelled"
          raise Abort, failure(error("offer_unsupported")) unless supported_offer?(ticket_type)

          @request_digest = request_digest_for(
            ticket_type,
            Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized_phone)
          )
          registration = idempotent_registration(key.digest, @request_digest)
          if registration
            outcome = success(registration)
            next
          end

          identity_result = Core::PhoneIdentity::ResolveOrCreate.call(
            phone: "+#{normalized_phone}",
            actor: nil,
            allow_actor_mismatch: true
          )
          raise Abort, identity_result if identity_result.failure?

          identity = identity_result.value
          registration = existing_active_registration(ticket_type, identity)
          raise Abort, failure(active_registration_error) if registration

          registration = Registration.create!(
            event:,
            ticket_type:,
            user: identity.user,
            created_by: @purchaser,
            source: "self_service",
            issuance_idempotency_key: key.digest,
            idempotency_request_digest: @request_digest,
            package_quantity: 1,
            admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
            party_size: ticket_type.admissions_per_unit,
            selected_event_date_id: @selected_event_date_id,
            identity_digest: identity.digest,
            status: "gift_pending_claim",
            submitted_at: Time.current
          )
          outcome = success(registration)
        end
        outcome
      rescue Abort => exception
        exception.result
      rescue ArgumentError
        failure(error("invalid_idempotency_key", status: :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error("offer_unsupported", status: :not_found))
      rescue ActiveRecord::RecordNotUnique
        replay_or_conflict(key&.digest, @request_digest)
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.gift_purchases.errors.invalid_registration"),
            code: "invalid_gift_registration",
            status: :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      end

      private

      def load_ticket_type
        Ticketing::TicketType.includes(event_product: :event).lock.find(@ticket_type_id)
      end

      def supported_offer?(ticket_type)
        ticket_type.event_product.type == "ticket" &&
          ticket_type.audience == "public" &&
          ticket_type.approval_mode == "automatic" &&
          !ticket_type.waitlist_enabled
      end

      attr_reader :normalized_phone

      def request_digest_for(ticket_type, identity_digest)
        Core::KeyedDigest.digest(
          namespace: "ticketing-gift-registration:#{ticket_type.event_product.event_id}",
          value: [
            ticket_type.id,
            @purchaser.id,
            identity_digest,
            @package_quantity.to_i,
            @selected_event_date_id.to_s
          ].join(":")
        )
      end

      def idempotent_registration(key_digest, request_digest)
        return if key_digest.blank?

        existing = Registration.lock.find_by(issuance_idempotency_key: key_digest)
        return unless existing
        return existing if existing.status == "gift_pending_claim" &&
          existing.idempotency_request_digest == request_digest

        raise Abort, failure(error("idempotency_conflict", status: :conflict))
      end

      def existing_active_registration(ticket_type, identity)
        Registration.blocking_duplicate.lock.find_by(
          ticket_type_id: ticket_type.id,
          identity_digest: identity.digest,
          selected_event_date_id: @selected_event_date_id
        )
      end

      def replay_or_conflict(key_digest, request_digest)
        existing = Registration.lock.find_by(issuance_idempotency_key: key_digest) if key_digest
        return success(existing) if existing&.status == "gift_pending_claim" &&
          existing.idempotency_request_digest == request_digest
        return failure(error("idempotency_conflict", status: :conflict)) if existing

        failure(active_registration_error)
      end

      def phone_identity_invalid
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.phone_identity_invalid"),
          code: "phone_identity_invalid",
          status: :unprocessable_entity
        )
      end

      def active_registration_error
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.active_registration_conflict"),
          code: "active_registration_conflict",
          status: :conflict
        )
      end

      def event_cancelled_error
        Core::BusinessError.new(
          I18n.t("ticketing.registration_workflows.errors.event_cancelled"),
          code: "event_cancelled",
          status: :conflict
        )
      end

      def error(key, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("ticketing.gift_purchases.errors.#{key}"),
          code: key == "idempotency_conflict" ? key : "gift_#{key}",
          status:
        )
      end
    end
  end
end
