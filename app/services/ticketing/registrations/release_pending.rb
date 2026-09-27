# frozen_string_literal: true

module Ticketing
  module Registrations
    # Cancels a buyer-owned pending registration and releases its audience
    # proof after Orders has serialized and released the linked checkout.
    class ReleasePending < Core::BaseService
      def initialize(registration:, buyer:, idempotency_key:, at: Time.current)
        @registration_id = registration.id
        @buyer = buyer
        @raw_idempotency_key = idempotency_key
        @at = at.to_time.utc
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        Registration.transaction do
          registration = Registration.lock.find(@registration_id)
          return failure(error(:registration_not_owned, status: :forbidden)) unless owned_by_buyer?(registration)
          return success(registration) if registration.status == "cancelled"
          return failure(error(:registration_not_releasable)) unless registration.pending_payment?

          registration.update!(status: "cancelled", cancelled_at: @at, next_action_snapshot: nil)
          proof_release = Ticketing::Registrations::AudienceProof::Release.call(
            registration:,
            reason: "buyer_requested",
            transition_key: "registration-pending-release-#{key.digest}",
            at: @at
          )
          raise proof_release.error if proof_release.failure?

          record_audit!(registration, key:)
          success(registration)
        end
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue Core::Error => exception
        failure(exception)
      rescue ActiveRecord::RecordNotFound
        failure(error(:registration_not_releasable, status: :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_registration, message: exception.message))
      end

      private

      def owned_by_buyer?(registration)
        registration.user_id == @buyer.id
      end

      def record_audit!(registration, key:)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-registration-pending-release-#{key.digest}",
          action: "ticketing.registration.pending_released",
          auditable_type: "Ticketing::Registration",
          auditable_id: registration.id,
          actor_type: "Core::User",
          actor_id: @buyer.id,
          audited_changes: {
            status: [ "pending_payment", "cancelled" ],
            cancelled_at: @at.iso8601
          },
          metadata: { source: "buyer_request" }
        )
        raise result.error if result.failure?
      end

      def error(key, message: nil, status: :conflict)
        Core::BusinessError.new(
          message || I18n.t("ticketing.registration_workflows.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
