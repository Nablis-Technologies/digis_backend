# frozen_string_literal: true

module Ticketing
  module Registrations
    # Atomically records a validated registration, immutable form evidence, and
    # exact-version consent requirements. Inventory and issuance remain downstream.
    class Submit < Core::BaseService
      class Halt < StandardError
        attr_reader :result

        def initialize(result)
          @result = result
          super(result.error.message)
        end
      end

      def initialize(ticket_type:, actor:, phone:, submission:, audience_proof:, idempotency_key: nil,
        guest: false, phone_confirmation: false, email: nil, full_name: nil)
        @ticket_type = ticket_type
        @actor = actor
        @phone = phone
        @submission = submission
        @audience_proof = audience_proof || {}
        @idempotency_key = idempotency_key
        @guest = guest == true
        @phone_confirmation = phone_confirmation == true
        @email = email
        @full_name = full_name
      end

      def call
        return failure(phone_confirmation_required) if guest? && !phone_confirmation

        identity_result = if guest?
          Core::PhoneIdentity::ResolveOrCreate.call(phone:, actor: nil, allow_actor_mismatch: true)
        else
          Core::PhoneIdentity::ResolveOrCreate.call(phone:, actor:)
        end
        return identity_result if identity_result.failure?

        identity = identity_result.value
        return failure(guest_requires_authentication) if guest? && !shadow_user?(identity.user)

        update_guest_identity!(identity.user) if guest?
        idempotency_key_digest = Core::IdempotencyKey.new(idempotency_key).digest if idempotency_key.present?
        idempotency_request_digest = nil
        locked_ticket_type = nil
        registration = Registration.transaction do
          locked_ticket_type = locked_ticket_type!
          idempotency_request_digest = request_digest(identity, locked_ticket_type)
          existing_registration = idempotent_registration(idempotency_key_digest, idempotency_request_digest) ||
            active_registration_or_conflict(identity, locked_ticket_type, idempotency_request_digest)
          if existing_registration
            existing_registration
          else
            audience = unwrap_audience(Ticketing::Audience::Authorize.call(
              ticket_type: locked_ticket_type,
              user: identity.user,
              **audience_proof
            ))
            access_code, invitation = consume_audience_proof!(
              locked_ticket_type, identity.user, audience
            )

            create_with_current_forms!(
              identity,
              idempotency_key_digest,
              idempotency_request_digest,
              next_action_snapshot(locked_ticket_type),
              locked_ticket_type,
              access_code:,
              invitation:
            )
          end
        end

        success(RegistrationNextAction.for(registration))
      rescue Halt => error
        error.result
      rescue ActiveRecord::RecordNotUnique
        keyed_registration = Registration.lock.find_by(issuance_idempotency_key: idempotency_key_digest)
        if keyed_registration
          return success(RegistrationNextAction.for(keyed_registration)) if
            keyed_registration.idempotency_request_digest == idempotency_request_digest

          return idempotency_conflict
        end

        registration = existing_active_registration(identity, locked_ticket_type || ticket_type)
        raise unless registration
        return active_registration_conflict unless same_registration_request?(
          registration,
          identity,
          locked_ticket_type || ticket_type,
          idempotency_request_digest
        )

        success(RegistrationNextAction.for(registration))
      rescue ArgumentError => error
        failure Core::BusinessError.new(error.message, code: "invalid_idempotency_key", status: :unprocessable_entity)
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.invalid_registration"),
          code: "invalid_registration",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :ticket_type, :actor, :phone, :submission, :audience_proof, :idempotency_key,
                  :email, :full_name

      def guest?
        @guest
      end

      def phone_confirmation
        @phone_confirmation
      end

      def shadow_user?(user)
        user.verified_at.blank? && user.password_digest.blank?
      end

      def update_guest_identity!(user)
        return if email.blank? || user.email.present? && user.email == email.to_s.strip.downcase

        user.email = email
        user.save!
      rescue ActiveRecord::RecordInvalid => error
        raise Halt, failure(
          Core::BusinessError.new(
            I18n.t("ticketing.registrations.errors.guest_identity_invalid"),
            code: "guest_identity_invalid",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      def create_with_current_forms!(identity, idempotency_key_digest, idempotency_request_digest,
        next_action_snapshot, locked_ticket_type, access_code:, invitation:)
        schema = unwrap(Ticketing::Forms::ApplicableSchema.call(
          event: locked_ticket_type.event,
          ticket_type: locked_ticket_type
        ))
        unwrap(Ticketing::Forms::ValidateSubmission.call(
          schema:,
          submission: validation_submission(locked_ticket_type)
        ))

        registration = Registration.create!(
          event: locked_ticket_type.event,
          ticket_type: locked_ticket_type,
          user: identity.user,
          access_code:,
          invitation:,
          created_by: actor || identity.user,
          source: "self_service",
          issuance_idempotency_key: idempotency_key_digest,
          idempotency_request_digest:,
          package_quantity: submission.package_quantity,
          admissions_per_unit_snapshot: locked_ticket_type.admissions_per_unit,
          party_size: submission.package_quantity.to_i * locked_ticket_type.admissions_per_unit,
          selected_event_date_id: submission.selected_event_date_id,
          identity_digest: identity.digest,
          status: locked_ticket_type.approval_mode == "manual" ? "pending_approval" : "pending_payment",
          next_action_snapshot:,
          submitted_at: Time.current
        )
        unwrap(Ticketing::Forms::PersistSubmission.call(
          registration:, schema:, submission: submission.to_h, actor: actor || identity.user
        ))
        unwrap(Ticketing::Consent::BuildRequirements.call(
          registration:,
          acceptances: submission.consents,
          actor: identity.user
        ))
        registration
      end

      def consume_audience_proof!(locked_ticket_type, user, authorization)
        access_code = invitation = nil
        if authorization[:access_code]
          access_code = unwrap_audience(Ticketing::AccessCodes::Consume.call(
            ticket_type: locked_ticket_type,
            raw_code: audience_proof[:access_code],
            quantity: submission.package_quantity
          ))
        elsif authorization[:invitation]
          invitation = unwrap_audience(Ticketing::Invitations::Claim.call(
            ticket_type: locked_ticket_type,
            raw_token: audience_proof[:invitation],
            user:,
            quantity: submission.package_quantity
          ))
        end
        [ access_code, invitation ]
      end

      def unwrap_audience(result)
        return result.value if result.success?

        error = if result.error.is_a?(Core::BusinessError)
          result.error
        else
          Core::BusinessError.new(
            result.error.message,
            code: "audience_proof_invalid",
            status: :unprocessable_entity
          )
        end
        raise Halt, failure(error)
      end

      def existing_active_registration(identity, locked_ticket_type)
        Registration.blocking_duplicate.lock.find_by(
          ticket_type_id: locked_ticket_type.id,
          identity_digest: identity.digest,
          selected_event_date_id: submission.selected_event_date_id
        )
      end

      def active_registration_or_conflict(identity, locked_ticket_type, idempotency_request_digest)
        registration = existing_active_registration(identity, locked_ticket_type)
        return unless registration
        return registration if same_registration_request?(registration, identity, locked_ticket_type, idempotency_request_digest)

        raise Halt, active_registration_conflict
      end

      # The database stores a keyed digest. Canonical JSON makes semantically
      # identical hashes and answer orderings produce an identical fingerprint.
      def idempotent_registration(idempotency_key_digest, idempotency_request_digest)
        return unless idempotency_key_digest

        registration = Registration.lock.find_by(issuance_idempotency_key: idempotency_key_digest)
        return unless registration
        return registration if registration.idempotency_request_digest == idempotency_request_digest

        raise Halt, idempotency_conflict
      end

      def request_digest(identity, locked_ticket_type)
        payload = {
          ticket_type_id: locked_ticket_type.id,
          identity_digest: identity.digest,
          package_quantity: submission.package_quantity.to_i,
          admissions_per_unit: locked_ticket_type.admissions_per_unit,
          selected_event_date_id: submission.selected_event_date_id.to_s.presence,
          answers: canonical_value(Array(submission.answers)),
          consents: canonical_value(Array(submission.consents)),
          audience_proof: canonical_value(audience_proof.compact_blank)
        }
        payload.merge!(guest: true, full_name: full_name.to_s.strip.presence) if guest?

        Core::KeyedDigest.digest(
          namespace: "ticketing-registration-request:#{locked_ticket_type.event_product.event_id}",
          value: ActiveSupport::JSON.encode(canonical_value(payload))
        )
      end

      def canonical_value(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical_value(nested) }
        when Array
          value.map { |nested| canonical_value(nested) }.sort_by { |nested| ActiveSupport::JSON.encode(nested) }
        else
          value
        end
      end

      def same_registration_request?(registration, identity, locked_ticket_type, idempotency_request_digest)
        registration.ticket_type_id == locked_ticket_type.id &&
          registration.user_id == identity.user.id &&
          registration.identity_digest == identity.digest &&
          registration.package_quantity == submission.package_quantity.to_i &&
          registration.admissions_per_unit_snapshot == locked_ticket_type.admissions_per_unit &&
          registration.selected_event_date_id.to_s == submission.selected_event_date_id.to_s &&
          registration.idempotency_request_digest == idempotency_request_digest
      end

      def active_registration_conflict
        failure Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.active_registration_conflict"),
          code: "active_registration_conflict",
          status: :unprocessable_entity
        )
      end

      def idempotency_conflict
        failure Core::BusinessError.new(
          I18n.t("idempotency.conflict"),
          code: "idempotency_conflict",
          status: :unprocessable_entity
        )
      end

      def validation_submission(locked_ticket_type)
        return unless submission.respond_to?(:to_h)

        submission.to_h.merge(admissions_per_unit: locked_ticket_type.admissions_per_unit)
      end

      def automatic_free?(locked_ticket_type)
        return false unless locked_ticket_type.approval_mode == "automatic"

        prices = locked_ticket_type.event_product.prices.active_at(Time.current)
        prices.exists? && prices.where.not(amount_minor: 0).none?
      end

      def next_action_snapshot(locked_ticket_type)
        status = locked_ticket_type.approval_mode == "manual" ? "pending_approval" : "pending_payment"
        RegistrationNextAction.type_for(status, free: automatic_free?(locked_ticket_type))
      end

      def locked_ticket_type!
        locked = Ticketing::TicketType.includes(event_product: :event).lock.find(ticket_type.id)
        event = Events::Event.lock.find(locked.event.id)
        raise Halt, Core::BaseService::Result.failure(event_cancelled_error) if event.status == "cancelled"

        locked
      end

      def event_cancelled_error
        Core::BusinessError.new(
          I18n.t("ticketing.registration_workflows.errors.event_cancelled"),
          code: "event_cancelled", status: :conflict
        )
      end

      def phone_confirmation_required
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.phone_confirmation_required"),
          code: "phone_confirmation_required",
          status: :bad_request
        )
      end

      def guest_requires_authentication
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.guest_requires_authentication"),
          code: "guest_requires_authentication",
          status: :conflict
        )
      end

      def unwrap(result)
        raise Halt, result if result.failure?

        result.value
      end
    end
  end
end
