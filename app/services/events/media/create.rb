# frozen_string_literal: true

module Events
  module Media
    class Create < Core::BaseService
      def initialize(event:, actor:, type:, position:, alt_text: nil, caption: nil, file:)
        @event = event
        @actor = actor
        @type = type
        @position = position
        @alt_text = alt_text
        @caption = caption
        @file = file
      end

      def call
        media = @event.event_media.build(
          type: @type, position: @position, alt_text: @alt_text,
          caption: @caption, created_by: @actor
        )
        attach_file(media)
        media.save!
        record_audit(media, "event.media.created")
        success(media)
      rescue ActiveRecord::RecordInvalid => e
        failure Core::BusinessError.new(
          I18n.t("events.event_media.errors.create"),
          code: "invalid", status: :unprocessable_entity, errors: e.record.errors.to_hash
        )
      end

      private

      def record_audit(media, action)
        Core::Audit::Record.call(
          audit_key: "event-media-#{action}-#{media.id}",
          action: action,
          auditable_type: "Events::EventMedia",
          auditable_id: media.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: media.attributes,
          metadata: { event_id: @event.id }
        )
      end

      def attach_file(media)
        return if @file.nil?

        media.file.attach(@file)
      end
    end
  end
end
