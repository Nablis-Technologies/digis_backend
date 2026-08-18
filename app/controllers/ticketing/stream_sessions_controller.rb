# frozen_string_literal: true

module Ticketing
  # Thin endpoints for playback-session creation, refresh, and revocation.
  # Ticket/credential authorization and provider capability checks remain in
  # the streaming services.
  class StreamSessionsController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present

    def create
      ticket = Ticketing::Ticket.find(params.require(:ticket_id))
      event_stream = Events::EventStream.find(params.require(:event_stream_id))
      authorize Ticketing::StreamSession.new(ticket:, event_stream:, user: current_user),
        :create?, policy_class: Ticketing::StreamSessionPolicy
      result = Streaming::Sessions::Create.call(
        ticket:,
        event_stream:,
        user: current_user,
        device_id: params.require(:device_id),
        idempotency_key:,
        now: Time.current
      )
      return render_service_result(result, success_status: :created) if result.failure?

      render_success(
        data: {
          session: result.value.session,
          session_token: result.value.session_token,
          playback_grant: result.value.playback_grant.to_h
        },
        status: :created,
        serializer_options: { session: { serializer: Ticketing::StreamSessionSerializer } }
      )
    end

    def refresh
      session = load_session
      authorize session, :refresh?, policy_class: Ticketing::StreamSessionPolicy
      result = Streaming::Sessions::Refresh.call(
        session:,
        session_token: params.require(:session_token),
        user: current_user,
        idempotency_key:,
        now: Time.current
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: {
          session: result.value.session,
          playback_grant: result.value.playback_grant.to_h
        },
        serializer_options: { session: { serializer: Ticketing::StreamSessionSerializer } }
      )
    end

    def revoke
      session = load_session
      authorize session, :revoke?, policy_class: Ticketing::StreamSessionPolicy
      result = Streaming::Sessions::Revoke.call(
        session:,
        session_token: params.require(:session_token),
        user: current_user,
        idempotency_key:,
        now: Time.current
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::StreamSessionSerializer }
      )
    end

    private

    def load_session
      Ticketing::StreamSession.find(params.require(:id))
    end
  end
end
