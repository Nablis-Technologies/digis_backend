# frozen_string_literal: true

module Events
  module Media
    class Update < Core::BaseService
      def initialize(media:, actor:, attributes:, file: nil)
        @media = media
        @actor = actor
        @attributes = attributes
        @file = file
      end

      def call
        @media.assign_attributes(@attributes)
        attach_file(@media) if @file
        @media.save!
        record_audit
        success(@media)
      rescue ActiveRecord::RecordInvalid => e
        failure Core::BusinessError.new(
          I18n.t("events.event_media.errors.update"),
          code: "invalid", status: :unprocessable_entity, errors: e.record.errors.to_hash
        )
      end

      private

      def record_audit
        fingerprint = Digest::SHA256.hexdigest(@attributes.to_s)[0, 12]
        Core::Audit::Record.call(
          audit_key: "event-media-update-#{@media.id}-#{fingerprint}",
          action: "event.media.updated",
          auditable_type: "Events::EventMedia",
          auditable_id: @media.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: @media.attributes,
          metadata: { event_id: @media.event_id }
        )
      end

      def attach_file(media)
        media.file.attach(@file)
      end
    end
  end
end
