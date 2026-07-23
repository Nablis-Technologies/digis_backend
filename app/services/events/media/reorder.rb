# frozen_string_literal: true

module Events
  module Media
    # Reorders a set of same-event media rows to sequential positions, keeping
    # the cover pinned at 0. Uses a temporary high-base position swap inside a
    # locked transaction so the unique (event_id, type, position) index is never
    # violated mid-reassignment (deferrable uniqueness is unavailable in
    # schema.rb, so we emulate it).
    class Reorder < Core::BaseService
      def initialize(event:, actor:, ordered_ids:)
        @event = event
        @actor = actor
        @ordered_ids = ordered_ids
      end

      def call
        normalized = Array(@ordered_ids).map(&:to_s)
        return failure(empty_error) if normalized.empty?

        requested = normalized.uniq
        records = @event.event_media.lock.where(id: requested).to_a
        return failure(missing_error(requested, records)) if records.size != requested.size

        # Covers stay pinned at 0; non-covers get a contiguous 1..n sequence in
        # the order supplied (covers don't consume a slot, so no gaps).
        positions = {}
        sequence = 0
        normalized.each do |id|
          next if records.find { |r| r.id.to_s == id }&.type == "cover"

          sequence += 1
          positions[id] = sequence
        end

        ActiveRecord::Base.transaction do
          records.each do |record|
            next unless positions.key?(record.id.to_s)

            # Temporary high-base positions stay >= 0 (check constraint) and
            # cannot collide with the final 1..n range, emulating deferrable
            # uniqueness (unavailable in schema.rb).
            record.update_columns(position: TEMP_BASE + positions[record.id.to_s])
          end
          records.each do |record|
            next unless positions.key?(record.id.to_s)

            record.update_columns(position: positions[record.id.to_s])
          end
        end

        record_audit
        success
      rescue ActiveRecord::RecordInvalid => e
        failure Core::BusinessError.new(
          I18n.t("events.event_media.errors.reorder"),
          code: "invalid", status: :unprocessable_entity, errors: e.record.errors.to_hash
        )
      end

      private

      TEMP_BASE = 1000

      def empty_error
        Core::BusinessError.new(
          I18n.t("events.event_media.errors.reorder"),
          code: "invalid", status: :unprocessable_entity,
          errors: { ordered_ids: [ "must not be empty" ] }
        )
      end

      def missing_error(requested, records)
        missing = requested - records.map(&:id).map(&:to_s)
        Core::BusinessError.new(
          I18n.t("events.event_media.errors.reorder"),
          code: "invalid", status: :unprocessable_entity,
          errors: { ordered_ids: [ "contains unknown ids: #{missing.join(', ')}" ] }
        )
      end

      def record_audit
        fingerprint = Digest::SHA256.hexdigest(@ordered_ids.to_s)[0, 12]
        Core::Audit::Record.call(
          audit_key: "event-media-reorder-#{@event.id}-#{fingerprint}",
          action: "event.media.reordered",
          auditable_type: "Events::Event",
          auditable_id: @event.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          metadata: { event_id: @event.id, ordered_ids: @ordered_ids }
        )
      end

      attr_reader :event, :actor, :ordered_ids
    end
  end
end
