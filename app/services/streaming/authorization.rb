# frozen_string_literal: true

module Streaming
  # Resolves ticket, credential, product-access, and live/replay eligibility
  # without consulting a provider. Provider capability is checked only after
  # this authoritative Digis decision succeeds.
  class Authorization < Core::BaseService
    Decision = Data.define(:ticket, :event_stream, :product_access, :window)

    def initialize(ticket:, event_stream:, user:, now: Time.current)
      @ticket = ticket
      @event_stream = event_stream
      @user = user
      @now = now
    end

    def call
      return failure(error(:stream_not_authorized, :forbidden)) unless @user
      return failure(error(:stream_not_authorized, :forbidden)) if @user.deactivated?
      return failure(error(:ticket_not_active, :conflict)) unless @ticket.status == "active"
      return failure(error(:package_dead, :conflict)) if @ticket.package_dead?
      return failure(error(:package_suspended, :conflict)) if @ticket.package_suspended?
      return failure(error(:stream_event_mismatch, :unprocessable_entity)) unless same_event?
      return failure(error(:stream_date_inactive, :conflict)) unless @event_stream.event_date.status.in?(%w[scheduled completed])

      generation = @ticket.current_credential_generation
      return failure(error(:stream_not_authorized, :forbidden)) unless requester_matches_generation?(generation)
      return failure(error(:credential_not_active, :conflict)) unless current_credential?(generation)
      return failure(error(:credential_date_revoked, :conflict)) unless generation.allows_event_date?(@event_stream.event_date_id)

      product_access = stream_access
      return failure(error(:stream_access_missing, :forbidden)) unless product_access

      window = playback_window
      return failure(window) if window.is_a?(Core::BusinessError)

      success(Decision.new(ticket: @ticket, event_stream: @event_stream, product_access:, window:))
    end

    private

    def same_event?
      @ticket.event_id == @event_stream.event_date.event_id
    end

    def current_credential?(generation)
      return false unless generation&.status == "active"

      credentials = generation.credentials
      if generation.mode == "group"
        return false unless @ticket.owner_user_id == @user.id

        credentials.any? { |credential| credential.type == "package" && credential.status == "active" }
      else
        credentials.any? do |credential|
          credential.type == "individual" &&
            credential.status == "active" &&
            credential.holder_user_id == @user.id
        end
      end
    end

    def requester_matches_generation?(generation)
      return false unless generation
      return @ticket.owner_user_id == @user.id if generation.mode == "group"

      generation.credentials.any? { |credential| credential.holder_user_id == @user.id }
    end

    def stream_access
      @ticket.event_product.product_accesses.find do |access|
        access.stream? && access.event_date_id == @event_stream.event_date_id
      end
    end

    def playback_window
      if live_window?
        return Streaming::Window.new(
          opens_at: @event_stream.live_from,
          closes_at: @event_stream.live_until,
          replay: false
        )
      end

      if replay_window?
        return Streaming::Window.new(
          opens_at: @event_stream.live_until,
          closes_at: @event_stream.replay_available_until,
          replay: true
        )
      end

      error(:stream_window_closed, :conflict)
    end

    def live_window?
      @event_stream.status == "live" && within?(@event_stream.live_from, @event_stream.live_until)
    end

    def replay_window?
      @event_stream.replay_enabled &&
        @event_stream.replay_available_until.present? &&
        @event_stream.status.in?(%w[live ended]) &&
        within?(@event_stream.live_until, @event_stream.replay_available_until) &&
        @now > @event_stream.live_until
    end

    def within?(opens_at, closes_at)
      @now >= opens_at && @now <= closes_at
    end

    def error(key, status)
      Core::BusinessError.new(
        I18n.t("streaming.errors.#{key}"),
        code: key.to_s,
        status:
      )
    end
  end
end
