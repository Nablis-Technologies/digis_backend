# frozen_string_literal: true

module Streaming
  # The server-authorized playback interval. Replay is a separate mode even
  # when its provider material is otherwise identical to live playback.
  Window = Data.define(:opens_at, :closes_at, :replay) do
    def initialize(opens_at:, closes_at:, replay:)
      fail ArgumentError, I18n.t("streaming.errors.window_interval_invalid") unless opens_at < closes_at

      super(opens_at:, closes_at:, replay: !!replay)
    end

    def replay? = replay
  end
end
