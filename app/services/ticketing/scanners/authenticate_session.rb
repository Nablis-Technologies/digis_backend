# frozen_string_literal: true

module Ticketing
  module Scanners
    # Resolves the single scanner bearer to an active event-scoped operator
    # context. Session possession, the staff assignment, and device scope are
    # all checked on every online scanner request.
    class AuthenticateSession < Core::BaseService
      Result = Data.define(:session, :device, :assignment, :operator)

      def initialize(token:, event:, now: Time.current)
        @token = token.to_s.strip
        @event = event
        @now = now
      end

      def call
        return failure(error(:token_required, :unauthorized)) if token.blank?
        return failure(error(:authentication_failed, :unauthorized)) unless token.match?(/\A[0-9a-f]{64}\z/)

        session = load_session
        return failure(error(:authentication_failed, :unauthorized)) unless session
        return failure(error(:assignment_not_found, :unauthorized)) unless session_assignment_matches_event?(session)
        return failure(error(:authentication_failed, :unauthorized)) unless session_live?(session)

        assignment = session.scanner_device_assignment
        return failure(error(:assignment_inactive, :unauthorized)) unless assignment.active?
        return failure(error(:assignment_outside_window, :unauthorized)) unless assignment.active_now?(now)
        return failure(error(:device_inactive, :unauthorized)) unless assignment.scanner_device.active?
        return failure(error(:device_scope_forbidden, :unauthorized)) unless device_in_event_scope?(assignment.scanner_device)
        return failure(error(:event_not_available, :unauthorized)) if event.status.in?(%w[cancelled completed])

        staff_assignment = assignment.event_staff_assignment
        return failure(error(:operator_forbidden, :forbidden)) unless active_scanner_operator?(session, staff_assignment)

        assignment.scanner_device.update!(last_seen_at: now)
        success(Result.new(
          session:,
          device: assignment.scanner_device,
          assignment:,
          operator: staff_assignment.user
        ))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :token, :event, :now

      def load_session
        Ticketing::ScannerSession.includes(
          :scanner_invitation,
          scanner_device_assignment: [
            :scanner_device,
            :event,
            { event_staff_assignment: :user },
            { assignment_zones: :access_zone }
          ]
        ).find_by(token_digest: Ticketing::ScannerSession.token_digest_for(token:))
      end

      def session_assignment_matches_event?(session)
        assignment = session.scanner_device_assignment
        assignment.event_id.to_s == event.id.to_s &&
          session.scanner_invitation.event_id.to_s == event.id.to_s
      end

      def session_live?(session)
        session.revoked_at.nil? &&
          session.expires_at > now &&
          session.scanner_invitation.status == "paired"
      end

      def active_scanner_operator?(session, staff_assignment)
        staff_assignment.active? &&
          staff_assignment.role == "scanner" &&
          staff_assignment.event_id == event.id &&
          staff_assignment.user_id == session.scanner_invitation.paired_user_id
      end

      def device_in_event_scope?(device)
        return true if device.organization_id == event.organization_id

        Events::EventOrganization.exists?(
          event_id: event.id,
          organization_id: device.organization_id,
          status: "active"
        )
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key.to_s,
          status:,
          errors:
        )
      end
    end
  end
end
