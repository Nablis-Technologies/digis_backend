# frozen_string_literal: true

module Ticketing
  module Exports
    # Consumes a fresh download proof before issuing a short-lived bearer URL.
    class AuthorizeDownload < Core::BaseService
      MAX_URL_LIFETIME = 2.minutes

      def initialize(attendee_export_id:, actor:, session_jti:, raw_proof:)
        @attendee_export_id = attendee_export_id
        @actor = actor
        @session_jti = session_jti
        @raw_proof = raw_proof
      end

      def call
        result = authorize_export
        return result if result.failure?

        export = result.value
        ttl = [ MAX_URL_LIFETIME, export.expires_at - Time.current ].min
        success(url: export.file.url(expires_in: ttl), expires_at: Time.current + ttl)
      rescue ActiveStorage::Error, ArgumentError
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.attendee_exports.errors.storage_unavailable"),
            code: "export_storage_unavailable",
            status: :unprocessable_entity
          )
        )
      end

      private

      def authorize_export
        AttendeeExport.transaction do
          event_id = AttendeeExport.where(id: @attendee_export_id).pick(:event_id)
          return failure(not_found_error) unless event_id

          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event_id)
          export = AttendeeExport.includes(:event).lock.find(@attendee_export_id)
          return failure(not_ready_error) unless export.status == "ready" && export.file.attached?
          return failure(expired_error) if export.expires_at <= Time.current
          return failure(unauthorized_error) unless authorized?(export)

          proof_result = Core::Reauthentication::Consume.call(
            user: @actor,
            session_jti: @session_jti,
            purpose: "attendee_export_download",
            raw_proof: @raw_proof
          )
          return proof_result if proof_result.failure?

          export.update!(last_download_authorized_at: Time.current)
          record_audit(export)
          success(export)
        end
      end

      def authorized?(export)
        Ticketing::AttendeeExportPolicy.new(@actor, export).download_authorizations?
      end

      def record_audit(export)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-attendee-export-download-authorized:#{export.id}:#{export.last_download_authorized_at.to_f}",
          action: "ticketing.attendee_export.download_authorized",
          auditable_type: export.class.name,
          auditable_id: export.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          metadata: {
            event_id: export.event_id,
            status: export.status,
            expires_at: export.expires_at
          }
        )
        raise result.error if result.failure?
      end

      def not_found_error
        Core::BusinessError.new(
          I18n.t("ticketing.attendee_exports.errors.not_found"),
          code: "export_not_found",
          status: :not_found
        )
      end

      def not_ready_error
        Core::BusinessError.new(
          I18n.t("ticketing.attendee_exports.errors.export_not_ready"),
          code: "export_not_ready",
          status: :conflict
        )
      end

      def expired_error
        Core::BusinessError.new(
          I18n.t("ticketing.attendee_exports.errors.export_expired"),
          code: "export_expired",
          status: :gone
        )
      end

      def unauthorized_error
        Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "not_authorized",
          status: :forbidden
        )
      end
    end
  end
end
