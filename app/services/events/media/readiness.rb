# frozen_string_literal: true

module Events
  module Media
    # Publication gate for event media: an event may publish only when it has a
    # cover that is attached, analyzed by Active Storage, and carries nonblank
    # alt text (accessibility requirement).
    class Readiness < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        cover = @event.event_media.cover.first
        ready = cover &&
                cover.file.attached? &&
                cover.file.blob.analyzed? &&
                cover.alt_text.present?

        if ready
          success(cover)
        else
          failure Core::BusinessError.new(
            I18n.t("events.event_media.errors.not_ready"),
            code: "media_not_ready", status: :unprocessable_entity
          )
        end
      end

      private

      attr_reader :event
    end
  end
end
