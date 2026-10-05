# frozen_string_literal: true

require "json"

module Core
  module Signups
    # Claims the phone identity proven by a signup-purpose OTP and upgrades its
    # shadow user without changing the identity referenced by guest purchases.
    class Complete < Core::BaseService
      Result = Data.define(:user, :access_token, :refresh_token)
      Upgrade = Data.define(:user, :replayed)
      PURPOSE = RequestOtp::PURPOSE

      def initialize(attributes:, verification_token:, idempotency_key:, request:)
        @attributes = attributes.to_h.symbolize_keys
        @verification_token = verification_token
        @raw_idempotency_key = idempotency_key
        @request = request
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        phone = Core::PhoneIdentity::ResolveOrCreate.normalize(@attributes[:phone])
        return failure(error(:phone_invalid, :unprocessable_entity)) if phone.blank?

        request_digest = request_digest_for(key:, phone:)
        audit_key = "core-auth-signup-#{key.digest}"
        replay = replay_user(audit_key:, request_digest:)
        return failure(replay.error) if replay&.failure?
        return tokens_for_authenticated(replay.value) if replay

        return failure(error(:phone_verification_required, :unprocessable_entity)) if @verification_token.blank?

        proof = Core::PhoneVerification::Verify.verify_proof(@verification_token)
        return failure(error(:verification_invalid, :forbidden)) unless proof
        return failure(error(:verification_invalid, :forbidden)) unless
          Core::PhoneVerification::Verify.valid_proof?(
            token: @verification_token,
            phone:,
            user_id: proof[:user_id],
            purpose: PURPOSE
          )

        outcome = upgrade_shadow!(
          user_id: proof.fetch(:user_id),
          challenge_id: proof.fetch(:challenge_id),
          verification_token: @verification_token,
          phone:,
          audit_key:,
          request_digest:
        )
        return failure(outcome.error) if outcome.failure?

        upgrade = outcome.value
        return tokens_for_authenticated(upgrade.user) if upgrade.replayed

        tokens_for(upgrade.user)
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error(:verification_invalid, :forbidden))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:signup_failed, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def upgrade_shadow!(user_id:, challenge_id:, verification_token:, phone:, audit_key:, request_digest:)
        user = nil
        outcome = nil

        ActiveRecord::Base.transaction do
          user = Core::User.lock.find(user_id)
          replay = replay_user(audit_key:, request_digest:)
          if replay
            outcome = if replay.failure?
              replay
            else
              success(Upgrade.new(user: replay.value, replayed: true))
            end
            next
          end

          Core::PhoneVerificationChallenge.lock.find_by!(
            id: challenge_id,
            user_id: user.id,
            purpose: PURPOSE
          )
          unless Core::PhoneVerification::Verify.valid_proof?(
            token: verification_token,
            phone:,
            user_id: user.id,
            purpose: PURPOSE
          )
            outcome = failure(error(:verification_invalid, :forbidden))
            next
          end
          unless phone_matches?(user, phone)
            outcome = failure(error(:verification_invalid, :forbidden))
            next
          end
          if user.password_digest.present? || user.verified_at.present?
            outcome = failure(error(:phone_taken, :unprocessable_entity))
            next
          end
          if @attributes[:password].blank?
            outcome = failure(error(
              :signup_failed,
              :unprocessable_entity,
              errors: [ I18n.t("auth.errors.password_required") ]
            ))
            next
          end
          if user.deactivated?
            outcome = failure(error(:account_deactivated, :forbidden))
            next
          end

          user.assign_attributes(signup_attributes(phone))
          user.verified_at = Time.current
          user.save!
          assign_default_role!(user)
          record_signup!(user, audit_key:, request_digest:)
          outcome = success(Upgrade.new(user:, replayed: false))
        end

        outcome
      end

      def signup_attributes(phone)
        attributes = { phone:, password: @attributes[:password], password_confirmation: @attributes[:password_confirmation] }
        attributes[:email] = @attributes[:email] if @attributes.key?(:email)
        attributes
      end

      def phone_matches?(user, phone)
        Core::PhoneIdentity::ResolveOrCreate.normalize(user.phone) == phone
      end

      def assign_default_role!(user)
        role = Core::Role.find_or_create_by!(code: "USER") do |record|
          record.name = "User"
          record.description = "Default end-user role"
          record.active = true
        end
        Core::UserRole.find_or_create_by!(user:, role:)
      end

      def record_signup!(user, audit_key:, request_digest:)
        audit = Core::Audit::Record.call(
          audit_key:,
          action: "core.user.signup_completed",
          auditable_type: user.class.name,
          auditable_id: user.id,
          actor_type: user.class.name,
          actor_id: user.id,
          audited_changes: { verified_at: user.verified_at.iso8601 },
          metadata: { request_digest:, method: "phone_otp" }
        )
        raise audit.error if audit.failure?
      end

      def replay_user(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit
        return failure(error(:idempotency_conflict, :conflict)) unless
          audit.metadata["request_digest"] == request_digest

        success(Core::User.find(audit.auditable_id))
      rescue ActiveRecord::RecordNotFound
        failure(error(:signup_failed, :unprocessable_entity))
      end

      def tokens_for(user)
        return failure(error(:account_deactivated, :forbidden)) if user.deactivated?

        tokens = Core::AuthService.call(operation: :generate_auth_tokens, user:, request: @request)
        return failure(tokens.error) if tokens.failure?

        success(Result.new(
          user:,
          access_token: tokens.value.fetch(:access_token),
          refresh_token: tokens.value.fetch(:refresh_token)
        ))
      end

      # An exact retry may recover a lost signup response, but it must not
      # reissue credentials after the password used for signup was changed.
      def tokens_for_authenticated(user)
        user.reload
        return failure(error(:invalid_credentials, :unauthorized)) unless
          user.authenticate(@attributes[:password])

        tokens_for(user)
      end

      def request_digest_for(key:, phone:)
        proof_digest = Core::KeyedDigest.digest(
          namespace: "core-auth-signup/verification-token",
          value: @verification_token
        )
        request = [
          Core::PhoneIdentity::ResolveOrCreate.digest_for(phone),
          @attributes[:email].to_s.strip.downcase,
          @attributes[:password].to_s,
          @attributes[:password_confirmation].to_s,
          proof_digest,
          key.digest
        ]
        Core::KeyedDigest.digest(namespace: "core-auth-signup/request", value: JSON.generate(request))
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("auth.errors.#{key}"),
          code: key.to_s,
          status:,
          errors:
        )
      end
    end
  end
end
