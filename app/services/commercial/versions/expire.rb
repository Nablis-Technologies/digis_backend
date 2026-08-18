# frozen_string_literal: true

module Commercial
  module Versions
    # Moves due scheduled or active versions to the terminal expired state.
    # The locked transition is append-only and replay-safe, so recurring job
    # overlap cannot create duplicate lifecycle evidence or rewrite definitions.
    class Expire < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(now: Time.current)
        @now = now.to_time.utc
      end

      def call
        due_version_ids.sum { |version_id| expire_one(version_id) }.then { |count| success(count) }
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::BusinessError.new(
          I18n.t("commercial.governance.errors.invalid_record"),
          code: "invalid_record", status: :unprocessable_entity, errors: error.record.errors.to_hash
        ))
      end

      private

      attr_reader :now

      def due_version_ids
        FeeScheduleVersion.where(status: %w[scheduled active])
          .where("effective_until IS NOT NULL AND effective_until <= ?", now)
          .order(:id).pluck(:id)
      end

      def expire_one(version_id)
        ActiveRecord::Base.transaction do
          version = FeeScheduleVersion.lock.find(version_id)
          return 0 unless version.status.in?(%w[scheduled active]) &&
            version.effective_until.present? && version.effective_until <= now

          before = version.status
          version.update!(status: "expired")
          transition_key = "commercial-version-expire-#{version.id}-#{version.effective_until.to_i}"
          record_transition!(
            target: version,
            actor: nil,
            audit_key: transition_key,
            action: "commercial.version.expired",
            audited_changes: { "status" => [ before, "expired" ] },
            metadata: { "effective_until" => version.effective_until.iso8601(6) },
            topic: "commercial",
            event_type: "commercial.version.expired",
            payload: { fee_schedule_version_id: version.id, status: version.status },
            outbox_key: transition_key
          )
          1
        end
      end
    end
  end
end
