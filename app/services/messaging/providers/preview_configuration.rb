# frozen_string_literal: true

module Messaging
  module Providers
    # Registers the fake transport only for an explicitly marked Render
    # preview. A misplaced enable flag fails closed instead of becoming a live
    # provider.
    class PreviewConfiguration
      ENABLE_FLAG = "DIGIS_MESSAGING_PREVIEW_PROVIDER"
      OUTCOME_VARIABLE = "DIGIS_MESSAGING_PREVIEW_OUTCOME"
      CHANNELS = %w[sms email].freeze

      class << self
        def call(env: ENV, registry:)
          return registry unless enabled?(env)

          reject_non_preview!(env)
          adapter = PreviewAdapter.new(outcome: env.fetch(OUTCOME_VARIABLE, "delivered"))
          CHANNELS.each { |channel| registry.register(channel:, adapter:) }
          registry
        end

        private

        def enabled?(env)
          env[ENABLE_FLAG] == "true"
        end

        def reject_non_preview!(env)
          return if env["RENDER_PREVIEW"] == "true"

          raise "#{ENABLE_FLAG} requires RENDER_PREVIEW=true"
        end
      end
    end
  end
end
