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

      outcome = nil
      # Lock every media row for the event and apply the reorder inside one
      # transaction so the pessimistic locks cover the writes and the audit is
      # committed atomically with the position changes.
      ActiveRecord::Base.transaction do
        all_media = @event.event_media.lock.to_a
        covers = all_media.select { |m| m.type == "cover" }
        galleries = all_media - covers
        gallery_ids = galleries.map { |m| m.id.to_s }

        # A partial list would collide with omitted rows' positions, so require
        # every non-cover media row to be present in the requested order.
        missing = requested - gallery_ids
        return failure(missing_error(requested, galleries)) unless missing.empty?
        extra = gallery_ids - requested
        return failure(partial_error) unless extra.empty?

        requested_records = requested.filter_map { |id| galleries.find { |m| m.id.to_s == id } }

        positions = {}
        sequence = 0
        requested_records.each do |record|
          sequence += 1
          positions[record.id.to_s] = sequence
        end

        requested_records.each do |record|
          # Temporary high-base positions stay >= 0 (check constraint) and
          # cannot collide with the final 1..n range, emulating deferrable
          # uniqueness (unavailable in schema.rb).
          record.update_columns(position: TEMP_BASE + positions[record.id.to_s])
        end
        requested_records.each do |record|
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
    rescue ActiveRecord::RecordNotUnique
      failure Core::BusinessError.new(
        I18n.t("events.event_media.errors.reorder"),
        code: "invalid", status: :unprocessable_entity
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

    def partial_error
      Core::BusinessError.new(
        I18n.t("events.event_media.errors.reorder_partial"),
        code: "invalid", status: :unprocessable_entity
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
