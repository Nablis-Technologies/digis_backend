# frozen_string_literal: true

module Ticketing
  module Checkins
    # Revalidates and corrects one online identity mismatch for an authorized
    # event manager. The shared admission consumer owns credential, schedule,
    # zone, revocation, and usage checks; this command only supplies the
    # append-only override context and durable correction evidence.
    class OverrideIdentityMismatch < Core::BaseService
      def initialize(checkin_log:, manager:, reason_code:, idempotency_key:, now: Time.current)
        @checkin_log = checkin_log
        @manager = manager
        @reason_code = reason_code.to_s.strip
        @idempotency_key = idempotency_key
        @now = now
      end

      def call
        Core::IdempotencyKey.new(@idempotency_key)
        return failure(error(:identity_override_invalid, :unprocessable_entity)) if @reason_code.blank?

        checkin = Ticketing::CheckinLog.find(@checkin_log.id)
        event = Events::Event.find(Ticketing::Ticket.where(id: checkin.ticket_id).pick(:event_id))
        return failure(error(:identity_override_forbidden, :forbidden)) unless
          Events::AuthorizationResolver.can_manage_catalog?(@manager, event)

        outcome = nil
        Ticketing::ApplicationRecord.transaction do
          checkin = Ticketing::CheckinLog.lock.find(checkin.id)
          existing = Ticketing::CheckinLog.find_by(overrides_checkin_log_id: checkin.id)
          if existing
            outcome = replay_or_conflict(existing)
            next
          end

          invalid = invalid_checkin(checkin)
          if invalid
            outcome = failure(invalid)
            next
          end

          outcome = append_override(checkin)
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:identity_override_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          error(
            :identity_override_invalid,
            :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      rescue ArgumentError
        failure(error(:identity_override_invalid, :unprocessable_entity))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def invalid_checkin(checkin)
        return error(:identity_override_not_possible, :conflict) unless checkin.result == "identity_mismatch"
        return error(:identity_override_not_possible, :conflict) if checkin.scan_upload_id.present?
        return error(:identity_override_not_possible, :conflict) unless checkin.identity_checked_by_id.present?
        return error(:identity_override_not_possible, :conflict) unless checkin.scanner_device_assignment_id.present?
        return error(:identity_override_not_possible, :conflict) if
          Ticketing::AdmissionUse.exists?(checkin_log_id: checkin.id)

        nil
      end

      def append_override(checkin)
        ticket = Ticketing::Ticket.lock.find(checkin.ticket_id)
        product_access = Catalog::ProductAccess.lock.find(checkin.product_access_id)
        assignment = Ticketing::ScannerDeviceAssignment.find_by(id: checkin.scanner_device_assignment_id)
        credential = Ticketing::Credential.includes(:credential_generation, :credential_revocation)
          .lock.find_by(id: checkin.credential_id, ticket_id: ticket.id)
        return failure(error(:identity_override_revalidation_failed, :conflict)) unless assignment && credential

        qr_result = Ticketing::Qr::Verifier.call(token: credential.qr_token)
        return failure(error(:identity_override_revalidation_failed, :conflict)) if qr_result.failure?

        result = Ticketing::Admissions::Consume.call(
          claims: qr_result.value,
          product_access:,
          assignment:,
          access_zone: Events::AccessZone.find_by(id: checkin.access_zone_id),
          client_scan_id: Ticketing::IdempotencyUuid.from(
            @idempotency_key,
            namespace: "ticketing-identity-override:#{checkin.id}"
          ),
          scanned_at: @now,
          lookup_via: checkin.lookup_via,
          reason_code: checkin.reason_code,
          identity_check: "mismatch",
          identity_checked_by: Core::User.find(checkin.identity_checked_by_id),
          now: @now,
          overrides_checkin_log: checkin,
          identity_override_by: @manager,
          identity_override_reason: @reason_code,
          identity_overridden_at: @now
        )
        return failure(error(:identity_override_revalidation_failed, :conflict)) if result.failure?
        return failure(error(:identity_override_revalidation_failed, :conflict)) unless result.value.result == "success"

        override = Ticketing::CheckinLog.includes(:admission_uses).find(result.value.id)
        record_audit!(override, checkin)
        publish_outbox!(override, checkin, ticket)
        success(override)
      end

      def replay_or_conflict(existing)
        expected_client_scan_id = Ticketing::IdempotencyUuid.from(
          @idempotency_key,
          namespace: "ticketing-identity-override:#{existing.overrides_checkin_log_id}"
        )
        return success(existing) if existing.client_scan_id == expected_client_scan_id &&
          existing.identity_override_by_id == @manager.id && existing.identity_override_reason == @reason_code

        failure(error(:idempotency_conflict, :conflict))
      end

      def record_audit!(override, mismatch)
        Core::Audit::Record.call(
          audit_key: "ticketing-identity-override-#{override.id}",
          action: "ticketing.checkin.identity_override_recorded",
          auditable_type: override.class.name,
          auditable_id: override.id,
          actor_type: @manager.class.name,
          actor_id: @manager.id,
          audited_changes: {
            overrides_checkin_log_id: [ nil, mismatch.id ],
            identity_override_reason: [ nil, @reason_code ]
          },
          metadata: { ticket_id: override.ticket_id, admission_use_count: override.admission_uses.size }
        )
      end

      def publish_outbox!(override, mismatch, ticket)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.checkin.identity_override_recorded",
          aggregate: override,
          payload: {
            checkin_log_id: override.id,
            overrides_checkin_log_id: mismatch.id,
            ticket_id: ticket.id,
            event_id: ticket.event_id,
            admission_use_count: override.admission_uses.size
          },
          idempotency_key: "ticketing-identity-override-#{override.id}"
        )
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
