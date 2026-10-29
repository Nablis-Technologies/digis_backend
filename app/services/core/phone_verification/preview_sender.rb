# frozen_string_literal: true

module Core
  module PhoneVerification
    # Test-only delivery seam for a private Render preview. It exposes the OTP
    # in preview logs for frontend testing and is never registered by default.
    class PreviewSender
      DEBUG_FLAG = "DIGIS_PREVIEW_DEBUG_LOGGING"

      def self.configure!(env:, config:)
        return config unless env[DEBUG_FLAG] == "true"
        raise "#{DEBUG_FLAG} requires RENDER_PREVIEW=true" unless env["RENDER_PREVIEW"] == "true"

        config.x.phone_verification_sender = new
        config
      end

      def call(phone:, code:, challenge:)
        Rails.logger.warn("[PREVIEW OTP] challenge_id=#{challenge.id} code=#{code}")
        true
      end
    end
  end
end
