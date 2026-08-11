# frozen_string_literal: true

module Ticketing
  module Exports
    # Makes due exports non-downloadable before retryable storage purging.
    class Expire < Core::BaseService
      ACTIVE_STATUSES = %w[pending processing ready failed].freeze

      def initialize(attendee_export_id:)
        @attendee_export_id = attendee_export_id
      end

      def call
        transition_result = transition_to_expiring
        return transition_result if transition_result.failure?
        return transition_result unless transition_result.value.status == "expiring"

        Purge.call(attendee_export_id: @attendee_export_id)
      end

      private

      def transition_to_expiring
        AttendeeExport.transaction do
          event_id = AttendeeExport.where(id: @attendee_export_id).pick(:event_id)
          return failure(not_found_error) unless event_id

          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event_id)
          export = AttendeeExport.lock.find(@attendee_export_id)
          return success(export) if export.status == "expired"
          return success(export) if export.status != "expiring" && export.expires_at > Time.current

          if ACTIVE_STATUSES.include?(export.status)
            export.update!(
              status: "expiring",
              processing_started_at: nil,
              ready_at: nil,
              failed_at: nil,
              failure_code: nil,
              expiring_at: Time.current
            )
          end

          success(export)
        end
      end

      def not_found_error
        Core::BusinessError.new(
          I18n.t("ticketing.attendee_exports.errors.not_found"),
          code: "export_not_found",
          status: :not_found
        )
      end
    end
  end
end
