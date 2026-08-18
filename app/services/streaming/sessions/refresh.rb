# frozen_string_literal: true

module Streaming
  module Sessions
    # Revalidates the ticket and current credential on every heartbeat. A
    # refresh can extend only to the current authorized window, never forever.
    class Refresh < Core::BaseService
      ResultValue = Data.define(:session, :playback_grant)

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
        Ticketing::StreamSession.transaction do
          session = load_session
          Core::Database::AdvisoryLock.acquire!("stream-session-refresh", session.id, @idempotency_key.digest)
          return failure(session_error(:stream_session_invalid)) unless session.token_matches?(@session_token)
          return failure(session_error(:stream_session_not_owned, status: :forbidden)) unless session.user_id == @user&.id
          return failure(session_error(:stream_session_revoked, status: :conflict)) if session.revoked?
          return expire(session) if session.expired?

          authorization = Streaming::Authorization.call(
            ticket: session.ticket,
            event_stream: session.event_stream,
            user: @user,
            now: @now
          )
          return authorization if authorization.failure?

          session.update!(
            last_seen_at: @now,
            expires_at: [ @now + 10.minutes, authorization.value.window.closes_at ].min
          )
          playback_grant = @provider_registry.for(session.event_stream).playback_grant(
            session:,
            window: authorization.value.window
          )
          success(ResultValue.new(session:, playback_grant:))
        end
      rescue Streaming::Providers::InvalidConfiguration
        failure(session_error(:streaming_provider_configuration_invalid))
      rescue Streaming::Providers::Error
        failure(session_error(:streaming_playback_unavailable))
      rescue ActiveRecord::RecordNotFound
        failure(session_error(:stream_session_not_found, status: :not_found))
      end

      private

      def load_session
        Ticketing::StreamSession.includes(
          ticket: [
            :event,
            :owner_user,
            :revocation,
            { current_credential_generation: :credentials,
              event_product: { product_accesses: :event_date } }
          ],
          event_stream: { event_date: :event }
        ).lock.find(@session.id)
      end

      def expire(session)
        session.update!(status: "expired") if session.status == "active"
        failure(session_error(:stream_session_expired, :conflict))
      end

      def session_error(key, status: :unprocessable_entity)
        Core::BusinessError.new(I18n.t("streaming.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
