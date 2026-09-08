# frozen_string_literal: true

module Ticketing
  module Registrations
    # Upgrades a shadow buyer after OTP proof. The registration remains the
    # historical ownership anchor; only the existing user identity is changed.
    class ClaimGuest < Core::BaseService
      Result = Data.define(:user, :access_token, :refresh_token)

      def initialize(registration:, phone:, verification_token:, password:, password_confirmation:,
        idempotency_key:, request:)
        @registration = registration
        @phone = phone
        @verification_token = verification_token
        @password = password
        @password_confirmation = password_confirmation
        @raw_idempotency_key = idempotency_key
        @request = request
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        request_digest = request_digest_for(key)
        audit_key = "ticketing-registration-claim-guest-#{@registration.id}-#{key.digest}"
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        proof = Core::PhoneVerification::Verify.verify_proof(@verification_token)
        return failure(error(:verification_invalid, :forbidden)) unless proof

        outcome = nil
        ActiveRecord::Base.transaction do
          registration = Ticketing::Registration.lock.find(@registration.id)
          user = Core::User.lock.find(registration.user_id)
          validation = validate(registration:, user:, proof:)
          if validation
            outcome = failure(validation)
            next
          end

          user.password = @password
          user.password_confirmation = @password_confirmation
          user.verified_at = Time.current
          user.save!

          audit = Core::Audit::Record.call(
            audit_key:,
            action: "ticketing.registration.guest_claimed",
            auditable_type: registration.class.name,
            auditable_id: registration.id,
            actor_type: user.class.name,
            actor_id: user.id,
            audited_changes: { status: "claimed", user_id: user.id },
            metadata: { registration_id: registration.id, request_digest: }
          )
          raise audit.error if audit.failure?

          outcome = success(user)
        end
        return outcome if outcome&.failure?

        tokens = Core::AuthService.call(operation: :generate_auth_tokens, user: outcome.value, request: @request)
        return failure(tokens.error) if tokens.failure?

        result = success(Result.new(
          user: outcome.value,
          access_token: tokens.value.fetch(:access_token),
          refresh_token: tokens.value.fetch(:refresh_token)
        ))
        Core::Telemetry.instrument(
          "ticketing.guest_checkout.claimed",
          aggregate_id: outcome.value.id,
          event_id: @registration.event_id,
          outcome: "claimed"
        ) { }
        result
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error(:registration_not_found, :not_found))
      rescue Core::Audit::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:claim_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      def request_digest_for(key)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(@phone)
        Core::KeyedDigest.digest(
          namespace: "ticketing-registration-guest-claim",
          value: [ @registration.id, Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized), key.digest ].join(":")
        )
      end

      def replay_result(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit
        return failure(error(:idempotency_conflict, :conflict)) unless audit.metadata["request_digest"] == request_digest

        user = Core::User.find(audit.actor_id)
        tokens = Core::AuthService.call(operation: :generate_auth_tokens, user:, request: @request)
        return failure(tokens.error) if tokens.failure?

        success(Result.new(
          user:,
          access_token: tokens.value.fetch(:access_token),
          refresh_token: tokens.value.fetch(:refresh_token)
        ))
      rescue ActiveRecord::RecordNotFound
        failure(error(:registration_not_found, :not_found))
      end

      def validate(registration:, user:, proof:)
        return error(:registration_not_claimable, :conflict) unless registration.status == "confirmed"
        return error(:claim_user_mismatch, :forbidden) unless proof.fetch(:user_id) == user.id.to_s
        return error(:claim_phone_mismatch, :forbidden) unless proof.fetch(:phone_digest) == user_phone_digest(user)
        return error(:claim_already_completed, :conflict) unless user.verified_at.blank? && user.password_digest.blank?
        return error(:password_invalid, :unprocessable_entity) unless @password.to_s.length >= 8
        return error(:password_mismatch, :unprocessable_entity) unless @password == @password_confirmation

        @phone_digest = user_phone_digest(user)
        nil
      end

      def user_phone_digest(user)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(user.phone)
        Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized)
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.guest_ticket.errors.#{key}"), code: key.to_s, status:, errors:
        )
      end
    end
  end
end
