# frozen_string_literal: true

require "digest"

  module Ticketing
    module ComplimentaryIssuance
      # Issues a manager-authorized zero-charge registration through the ordinary
      # forms, consent, limits, inventory, and confirmation pipeline. It creates
      # no order, payment, fee, refund, or other financial record.
      class Issue < Core::BaseService
      include Ticketing::Registrations::Support

      def initialize(ticket_type:, actor:, phone:, package_quantity:, reason:, idempotency_key:,
        selected_event_date_id: nil, answers: [], consents: [])
        @ticket_type = ticket_type
        @actor = actor
        @phone = phone
        @package_quantity = package_quantity.to_i
        @reason = reason
        @idempotency_key = idempotency_key
        @selected_event_date_id = selected_event_date_id
        @answers = answers || []
        @consents = consents || []
      end

      def call
        key = Core::IdempotencyKey.new(idempotency_key)
        halt("complimentary_unauthorized") unless authorized_actor?
        halt("complimentary_reason_invalid") unless Registration::COMPLIMENTARY_REASONS.include?(reason)
        halt("package_quantity_invalid") unless package_quantity.positive?

        issued = Ticketing::Registration.transaction do
          ticket_type = Ticketing::TicketType.lock
            .includes(event_product: [ :event, :prices ])
            .find(@ticket_type.id)
          event = Events::Event.lock.find(ticket_type.event_product.event_id)
          halt("event_cancelled") if event.status == "cancelled"
          ticket_type.event_product.association(:event).target = event
          identity = unwrap(Core::PhoneIdentity::ResolveOrCreate.call(
            phone:,
            actor:,
            allow_actor_mismatch: true
          ))
          request_digest = request_digest_for(key, identity.digest, ticket_type)
          existing = Ticketing::Registration.lock.find_by(issuance_idempotency_key: key.digest)
          if existing
            halt("idempotency_conflict") unless existing.idempotency_request_digest == request_digest
            next existing
          end

          registration = Ticketing::Registration.create!(
            event: ticket_type.event,
            ticket_type:,
            user: identity.user,
            created_by: actor,
            source: "organizer_complimentary",
            issuance_idempotency_key: key.digest,
            idempotency_request_digest: request_digest,
            complimentary_reason: reason,
            identity_digest: identity.digest,
            package_quantity:,
            admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
            party_size: package_quantity * ticket_type.admissions_per_unit,
            selected_event_date_id:,
            status: "pending_payment",
            next_action_snapshot: "requires_confirmation",
            submitted_at: Time.current
          )
          persist_forms!(registration, ticket_type)
          unwrap(Ticketing::Consent::BuildRequirements.call(
            registration:,
            acceptances: consents,
            actor: identity.user
          ))
          unwrap(reserve_capacity!(registration, idempotency_key: "#{key.digest}:complimentary"))
          confirmed = unwrap(Ticketing::Registrations::ConfirmFree.call(
            registration:,
            actor:,
            idempotency_key: "#{key.digest}:complimentary-confirmation"
          ))
          record_audit!(confirmed, key)
          confirmed
        end

        success(issued)
      rescue Ticketing::Registrations::Support::Halt => error
        error.result
      rescue ArgumentError
        failure(workflow_error("invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.registration_workflows.errors.invalid_registration"),
            code: "invalid_registration",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :ticket_type, :actor, :phone, :package_quantity, :reason, :idempotency_key,
                  :selected_event_date_id, :answers, :consents

      def authorized_actor?
        actor.present? && Events::AuthorizationResolver.can_manage_catalog?(actor, ticket_type.event)
      end

      def request_digest_for(key, identity_digest, ticket_type)
        payload = {
          idempotency_key: key.to_s,
          ticket_type_id: ticket_type.id,
          identity_digest:,
          package_quantity:,
          selected_event_date_id: selected_event_date_id.to_s.presence,
          reason:,
          answers: canonical_value(answers),
          consents: canonical_value(consents)
        }
        Core::KeyedDigest.digest(
          namespace: "ticketing-complimentary-registration:#{ticket_type.event_product.event_id}",
          value: ActiveSupport::JSON.encode(canonical_value(payload))
        )
      end

      def persist_forms!(registration, ticket_type)
        # Complimentary issuance bypasses public audience proof, not the
        # registration form and buyer-consent requirements.
        schema = unwrap(Ticketing::Forms::ApplicableSchema.call(
          event: ticket_type.event,
          ticket_type:
        ))
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity:,
          selected_event_date_id:,
          answers:,
          consents:
        )
        unwrap(Ticketing::Forms::ValidateSubmission.call(
          schema:,
          submission: submission.to_h.merge(admissions_per_unit: ticket_type.admissions_per_unit)
        ))
        unwrap(Ticketing::Forms::PersistSubmission.call(
          registration:,
          schema:,
          submission: submission,
          actor:
        ))
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

      def record_audit!(registration, key)
        unwrap(Core::Audit::Record.call(
          audit_key: "ticketing-complimentary-issue-#{key.digest}",
          action: "ticketing.registration.complimentary_issued",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { status: [ "pending_payment", "confirmed" ] },
          metadata: { event_id: registration.event_id, reason: }
        ))
      end

      def halt(code)
        fail Ticketing::Registrations::Support::Halt,
          Core::BaseService::Result.failure(workflow_error(code))
      end
      end
    end
  end
