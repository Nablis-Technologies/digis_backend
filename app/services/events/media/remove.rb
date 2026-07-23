# frozen_string_literal: true

module Events
  module Media
    # Removes a media row and schedules the attached blob for after-commit
    # purge. No external work happens inside the destroy transaction.
    class Remove < Core::BaseService
      def initialize(media:, actor:)
        @media = media
        @actor = actor
      end

      def call
        blob_id = @media.file.blob_id if @media.file.attached?
        @media.destroy!
        Events::PurgeEventMediaJob.perform_later(blob_id) if blob_id
        record_audit
        success
      rescue ActiveRecord::RecordNotDestroyed => e
        failure Core::BusinessError.new(
          I18n.t("events.event_media.errors.destroy"),
          code: "invalid", status: :unprocessable_entity, errors: e.record.errors.to_hash
        )
      end

      private

      def record_audit
        Core::Audit::Record.call(
          audit_key: "event-media-removed-#{@media.id}",
          action: "event.media.removed",
          auditable_type: "Events::EventMedia",
          auditable_id: @media.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          metadata: { event_id: @media.event_id }
        )
      end

      attr_reader :media, :actor
    end
  end
end
