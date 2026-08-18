# frozen_string_literal: true

module Streaming
  module Sessions
    # Revokes Digis authority immediately. Provider cleanup is best-effort at
    # this boundary; authoritative local state must not depend on a provider.
    class Revoke < Core::BaseService
      def initialize(session:, session_token:, user:, now: Time.current, idempotency_key:,
                     provider_registry: Streaming::Providers::Registry)
        @session = session
        @session_token = session_token
        @user = user
        @now = now
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
        @provider_registry = provider_registry
      end

      def call
        session = nil
        Ticketing::StreamSession.transaction do
          session = Ticketing::StreamSession.includes(:event_stream).lock.find(@session.id)
          Core::Database::AdvisoryLock.acquire!("stream-session-revoke", session.id, @idempotency_key.digest)
          return failure(session_error(:stream_session_invalid)) unless session.token_matches?(@session_token)
          return failure(session_error(:stream_session_not_owned, status: :forbidden)) unless session.user_id == @user&.id

          session.update!(status: "revoked", revoked_at: @now) unless session.revoked?
        end

        begin
          @provider_registry.for(session.event_stream).revoke_playback(session:)
        rescue Streaming::Providers::Error
          # Local revocation remains the security boundary; lifecycle cleanup
          # is retried by the later streaming outbox/job task.
        end
        success(session)
      rescue ActiveRecord::RecordNotFound
        failure(session_error(:stream_session_not_found, status: :not_found))
      end

      private

      def session_error(key, status: :unprocessable_entity)
        Core::BusinessError.new(I18n.t("streaming.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
