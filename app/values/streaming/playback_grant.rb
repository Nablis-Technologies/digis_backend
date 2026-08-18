# frozen_string_literal: true

module Streaming
  # Provider-neutral playback material. A grant may contain an embed id, a
  # URL, or a future signed-provider token, but never Digis session secrets.
  PlaybackGrant = Data.define(
    :provider,
    :playback_type,
    :playback_url,
    :embed_id,
    :token,
    :expires_at
  ) do
    PLAYBACK_TYPES = %w[embed hls url].freeze

    def initialize(provider:, playback_type:, playback_url:, embed_id:, token:, expires_at:)
      fail ArgumentError, I18n.t("streaming.errors.provider_required") if provider.blank?
      fail ArgumentError, I18n.t("streaming.errors.unsupported_playback_type") unless PLAYBACK_TYPES.include?(playback_type)
      fail ArgumentError, I18n.t("streaming.errors.expires_at_required") if expires_at.nil?
      fail ArgumentError, I18n.t("streaming.errors.embed_id_required") if playback_type == "embed" && embed_id.blank?
      fail ArgumentError, I18n.t("streaming.errors.playback_url_required") if playback_type != "embed" && playback_url.blank?

      super
    end
  end
end
