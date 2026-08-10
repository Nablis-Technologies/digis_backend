# frozen_string_literal: true

module Core
  module Reauthentication
    # Atomically consumes a valid proof after rechecking the user and session state.
    class Consume < Core::BaseService
      def initialize(user:, session_jti:, purpose:, raw_proof:)
        @user = user
        @session_jti = session_jti
        @purpose = purpose
        @raw_proof = raw_proof
      end

      def call
        return invalid_proof unless valid_input?

        ActiveRecord::Base.transaction do
          user = locked_user
          session = locked_session(user)
          next invalid_proof unless active_user?(user) && active_session?(session)

          consumed_at = Time.current
          consumed = matching_proofs.update_all(consumed_at: consumed_at, updated_at: consumed_at)
          consumed == 1 ? success : invalid_proof
        end
      end

      private

      def valid_input?
        Core::ReauthenticationProof::PURPOSES.include?(@purpose) &&
          @session_jti.present? && @raw_proof.is_a?(String) &&
          @raw_proof.match?(Core::ReauthenticationProof::DIGEST_FORMAT)
      end

      def locked_user
        Core::User.lock.find_by(id: @user&.id)
      end

      def locked_session(user)
        return unless user

        Core::RefreshToken.lock.find_by(user_id: user.id, jti: @session_jti)
      end

      def active_user?(user)
        user.present? && !user.deactivated?
      end

      def active_session?(session)
        session&.active?
      end

      def matching_proofs
        Core::ReauthenticationProof
          .where(
            user_id: @user.id,
            session_jti_digest: digest_session_jti,
            purpose: @purpose,
            token_digest: digest_proof
          )
          .where(consumed_at: nil)
          .where("expires_at > ?", Time.current)
      end

      def digest_session_jti
        Core::KeyedDigest.digest(namespace: "core/reauthentication/session_jti", value: @session_jti)
      end

      def digest_proof
        Core::KeyedDigest.digest(
          namespace: "core/reauthentication/proof/#{@purpose}",
          value: @raw_proof
        )
      end

      def invalid_proof
        failure(
          Core::BusinessError.new(
            I18n.t("reauthentication.errors.invalid_proof"),
            code: I18n.t("reauthentication.codes.invalid_proof"),
            status: 401
          )
        )
      end
    end
  end
end
