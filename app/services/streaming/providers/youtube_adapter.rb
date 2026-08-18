# frozen_string_literal: true

module Streaming
  module Providers
    # Honest launch adapter for public and soft-gated YouTube embeds. Digis
    # controls authorization to its playback surface, not a copied YouTube URL.
    class YouTubeAdapter < BaseAdapter
      SUPPORTED_ACCESS_PROTECTIONS = %w[public soft_gated].freeze
      CONFIG_KEYS = %w[privacy_status privacy_evidence privacy_checked_at].freeze

      def playback_grant(session:, window:)
        event_stream = session.event_stream
        validate_configuration!(event_stream)
        video_id = event_stream.provider_playback_id
        fail PlaybackUnavailable, I18n.t("streaming.errors.youtube_playback_id_missing") if video_id.blank?

        Streaming::PlaybackGrant.new(
          provider: "youtube",
          playback_type: "embed",
          playback_url: nil,
          embed_id: video_id,
          token: nil,
          expires_at: [ window.closes_at, session.expires_at ].min
        )
      end

      def revoke_playback(session:)
        true
      end

      def supported_access_protections = SUPPORTED_ACCESS_PROTECTIONS

      def validate_configuration!(event_stream)
        super
        config = event_stream.config.to_h.stringify_keys
        unknown = config.keys - CONFIG_KEYS
        fail InvalidConfiguration, I18n.t("streaming.errors.youtube_configuration_unknown_keys") if unknown.any?

        return unless event_stream.access_protection == "soft_gated"
        return if config["privacy_status"] == "unlisted" && config["privacy_evidence"].present?

        fail InvalidConfiguration, I18n.t("streaming.errors.youtube_privacy_evidence_required")
      end
    end
  end
end
