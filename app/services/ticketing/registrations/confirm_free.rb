  # frozen_string_literal: true

  module Ticketing
    module Registrations
      # Commits already-reserved capacity for a free registration and publishes
      # the privacy-safe issuance handoff only after confirmation is durable.
      class ConfirmFree < Core::BaseService
      include Support

      def initialize(registration:, actor: nil, idempotency_key: nil)
        @registration = registration
        @actor = actor || registration.user
        @idempotency_key = idempotency_key || "ticketing-registration-confirm-free-#{registration.id}"
      end

      def call
        confirmed = Ticketing::Registration.transaction do
          event_id = Ticketing::Registration.where(id: @registration.id).pick(:event_id)
          event = Events::Event.lock.find(event_id)
          locked = Ticketing::Registration.lock
            .includes(:user, :consent_requirements)
            .find(@registration.id)
          return success(locked) if locked.confirmed?
          return failure(workflow_error("event_cancelled")) if event.status == "cancelled"
          return failure(workflow_error("registration_not_confirmable")) unless
            locked.status.in?(%w[pending_payment offered])
          return failure(workflow_error("required_buyer_consent_missing")) unless
            required_buyer_consents_complete?(locked)

          unwrap(commit_capacity!(locked, idempotency_key: @idempotency_key))
          now = Time.current
          locked.update!(
            status: "confirmed",
            approved_at: locked.approved_at || now,
            confirmed_at: now,
            waitlisted_at: nil,
            offered_at: nil,
            offer_expires_at: nil,
            next_action_snapshot: nil
          )
          publish_issuance_ready!(locked)
          locked
        end

        success(confirmed)
      rescue Support::Halt => error
        error.result
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

      def publish_issuance_ready!(registration)
        unwrap(Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.registration.issuance_ready",
          aggregate: registration,
          payload: { registration_id: registration.id },
          idempotency_key: "ticketing-registration-issuance-ready-#{registration.id}"
        ))
      end
      end
    end
  end
