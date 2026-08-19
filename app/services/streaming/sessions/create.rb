# frozen_string_literal: true

require "securerandom"

module Streaming
  module Sessions
    # Creates a short-lived playback session after Digis authorizes the current
    # ticket holder. Device counting is serialized before the session row is
    # inserted; the provider receives only an already-authorized session.
    class Create < Core::BaseService
      ResultValue = Data.define(:session, :session_token, :playback_grant)

      def initialize(ticket:, event_stream:, user:, device_id:, now: Time.current, idempotency_key:,
                     provider_registry: Streaming::Providers::Registry)
        @ticket = ticket
        @event_stream = event_stream
        @user = user
        @device_id = device_id.to_s.strip
        @now = now
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
        @provider_registry = provider_registry
      end

      def call
        return failure(provider_error(:stream_device_id_required, status: :bad_request)) if normalized_device_id.blank?

        Ticketing::StreamSession.transaction do
          ticket = load_ticket
          event_stream = load_event_stream
          authorization = Streaming::Authorization.call(ticket:, event_stream:, user: @user, now: @now)
          return authorization if authorization.failure?

          lock_device_scope!(ticket, event_stream)
          return failure(device_limit_error) if device_limit_reached?(ticket, event_stream)

          session_token = SecureRandom.urlsafe_base64(48)
          session = Ticketing::StreamSession.create!(
            ticket:,
            event_stream:,
            user: @user,
            device_id: normalized_device_id,
            session_token_digest: Ticketing::StreamSession.token_digest_for(token: session_token),
            status: "active",
            expires_at: [ @now + 10.minutes, authorization.value.window.closes_at ].min
          )
          adapter = @provider_registry.for(event_stream)
          playback_grant = adapter.playback_grant(session:, window: authorization.value.window)

          success(ResultValue.new(session:, session_token:, playback_grant:))
        end
      rescue Streaming::Providers::InvalidConfiguration
        failure(provider_error(:streaming_provider_configuration_invalid))
      rescue Streaming::Providers::Error
        failure(provider_error(:streaming_playback_unavailable))
      rescue ArgumentError
        failure(provider_error(:streaming_session_invalid))
      rescue ActiveRecord::RecordNotFound
        failure(provider_error(:stream_session_not_found, status: :not_found))
      end

      private

      def load_ticket
        Ticketing::Ticket.includes(
          :event,
          :owner_user,
          :revocation,
          current_credential_generation: :credentials,
          event_product: { product_accesses: :event_date }
        ).lock.find(@ticket.id)
      end

      def load_event_stream
        Events::EventStream.includes(event_date: :event).lock.find(@event_stream.id)
      end

      def lock_device_scope!(ticket, event_stream)
        Core::Database::AdvisoryLock.acquire!("stream-session", ticket.id, event_stream.id)
        Core::Database::AdvisoryLock.acquire!("stream-session-request", @idempotency_key.digest)
      end

      def device_limit_reached?(ticket, event_stream)
        active_devices = Ticketing::StreamSession
          .where(ticket_id: ticket.id, event_stream_id: event_stream.id, status: "active")
          .where("expires_at > ?", @now)
          .where.not(device_id: normalized_device_id)
          .distinct
          .count(:device_id)

        active_devices >= event_stream.max_concurrent_devices.to_i
      end

      def normalized_device_id
        @device_id.presence
      end

      def device_limit_error
        provider_error(:stream_device_limit_reached, status: :conflict)
      end

      def provider_error(key, status: :unprocessable_entity)
        Core::BusinessError.new(I18n.t("streaming.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
