# frozen_string_literal: true

module Core
  module Reauthentication
    # Verifies the current user's password and issues one opaque session-bound proof.
    class Issue < Core::BaseService
      def initialize(user:, session_jti:, purpose:, password:, ip_address: nil)
        @user = user
        @session_jti = session_jti
        @purpose = purpose
        @password = password
        @ip_address = ip_address
      end

      def call
        return failure_for(:unsupported_purpose, 422) unless supported_purpose?
        return failure_for(:invalid_session, 401) if @session_jti.blank?
        return failure_for(:inactive_user, 401) unless active_user?

        issuance_result = issuance_throttle
        return issuance_result if issuance_result.failure?
        return password_failure unless password_authenticated?

        raw_proof = SecureRandom.hex(32)
        create_proof(raw_proof)
        success(raw_proof)
      end

      private

      def supported_purpose?
        Core::ReauthenticationProof::PURPOSES.include?(@purpose)
      end

      def active_user?
        @user.present? && !@user.deactivated?
      end

      def password_authenticated?
        @password.present? && @user.authenticate(@password)
      end

      def password_failure
        result = Throttle.call(
          user: @user,
          session_jti: @session_jti,
          purpose: @purpose,
          ip_address: @ip_address,
          failed_password: true
        )
        return result if result.failure?

        failure_for(:invalid_password, 401)
      end

      def issuance_throttle
        Throttle.call(
          user: @user,
          session_jti: @session_jti,
          purpose: @purpose,
          ip_address: @ip_address
        )
      end

      def create_proof(raw_proof)
        issued_at = Time.current
        Core::ReauthenticationProof.create!(
          user: @user,
          session_jti_digest: digest_session_jti,
          purpose: @purpose,
          factor_type: "password",
          token_digest: digest_proof(raw_proof),
          issued_at: issued_at,
          expires_at: issued_at + Core::ReauthenticationProof::LIFETIME
        )
      end

      def digest_session_jti
        Core::KeyedDigest.digest(namespace: "core/reauthentication/session_jti", value: @session_jti)
      end

      def digest_proof(raw_proof)
        Core::KeyedDigest.digest(
          namespace: "core/reauthentication/proof/#{@purpose}",
          value: raw_proof
        )
      end

      def failure_for(key, status)
        failure(
          Core::BusinessError.new(
            I18n.t("reauthentication.errors.#{key}"),
            code: I18n.t("reauthentication.codes.#{key}"),
            status: status
          )
        )
      end
    end
  end
end
