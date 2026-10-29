# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Consumes an event-owned invitation and atomically binds operator, device,
    # assignment, and a single scanner Bearer session. No Core JWT is issued.
    class PairInvitation < Core::BaseService
      Result = Data.define(:invitation, :session, :scanner_session_token, :replayed) do
        def replayed? = replayed
      end

      CODE_ATTEMPT_LIMIT = 3
      IP_CODE_ATTEMPT_LIMIT = 30
      CODE_ATTEMPT_WINDOW = 10.minutes
      INSTALLATION_ID_PATTERN = /\A[a-zA-Z0-9:_-]{8,128}\z/

      def initialize(pairing_token: nil, pairing_code: nil, pairing_method:, installation_id:, device_name: nil,
        ip_address:, idempotency_key:, at: Time.current, cache: Rails.cache)
        @pairing_token = pairing_token.to_s.strip.presence
        @pairing_code = pairing_code.to_s.strip.presence
        @pairing_method = pairing_method.to_s
        @installation_id = installation_id.to_s.strip
        @device_name = device_name.to_s.strip.presence
        @ip_address = ip_address.to_s
        @idempotency_key_input = idempotency_key
        @at = at
        @cache = cache
      end

      def call
        key = idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(error(:scanner_pairing_parameters_invalid, :bad_request)) unless valid_input?

        request_digest = pairing_request_digest
        key_digest = pairing_key_digest(key)
        replay = replay_session(key_digest:, request_digest:)
        return replay if replay
        return failure(error(:pairing_rate_limited, :too_many_requests)) if pairing_code.present? && code_attempt_limited?

        invitation = find_invitation
        return failure(error(:pairing_invalid, :unauthorized)) unless invitation

        event = Events::Event.find(invitation.event_id)
        result = nil
        ActiveRecord::Base.transaction do
          event.lock!
          locked = Ticketing::ScannerInvitation.lock.find(invitation.id)
          replay = replay_session(key_digest:, request_digest:)
          if replay
            result = replay
            next
          end

          current = current_capability?(locked)
          unless current && locked.pairable_at?(at) && !event.status.in?(%w[cancelled completed]) &&
              capability_unexpired?(locked)
            result = failure(error(:pairing_invalid, :unauthorized))
            next
          end

          operator_result = Core::PhoneIdentity::ResolveOrCreate.call(
            phone: locked.phone,
            actor: locked.created_by,
            allow_actor_mismatch: true
          )
          unless operator_result.success?
            result = failure(error(:phone_identity_invalid, :unprocessable_entity))
            next
          end
          operator = operator_result.value.user

          staff_assignment = if locked.status == "pairing_reset"
            existing_staff_assignment(locked, operator)
          else
            grant = delegated_grant(locked)
            assignment_result = Events::StaffAssignments::AssignFromDelegatedGrant.call(
              event:,
              organization: event.organization,
              user: operator,
              grant:
            )
            unless assignment_result.success?
              result = failure(assignment_result.error)
              next
            end
            assignment_result.value
          end
          unless staff_assignment
            result = failure(error(:scanner_staff_assignment_inactive, :conflict))
            next
          end

          grant = delegated_grant(locked)
          device_result = Ticketing::Scanners::RegisterDevice.call(
            event:,
            delegated_grant: grant,
            device_identifier: installation_id,
            name: device_name
          )
          unless device_result.success?
            result = failure(device_result.error)
            next
          end

          assignment_result = Ticketing::Scanners::AssignToEvent.call(
            scanner_device: device_result.value.device,
            event:,
            event_staff_assignment: staff_assignment,
            delegated_grant: grant,
            zone_mode: locked.zone_mode,
            zone_ids: locked.selected_zone_ids,
            starts_at: locked.starts_at,
            ends_at: locked.ends_at
          )
          unless assignment_result.success?
            result = failure(assignment_result.error)
            next
          end

          previous_status = locked.status
          delivery_status = locked.delivery_status == "queued" ? "unknown" : locked.delivery_status
          locked.update!(
            status: "paired",
            paired_user: operator,
            event_staff_assignment: staff_assignment,
            scanner_device: device_result.value.device,
            scanner_device_assignment: assignment_result.value,
            pairing_method:,
            paired_at: at,
            token_ciphertext: nil,
            pairing_code_ciphertext: nil,
            delivery_status:
          )
          session_token = SecureRandom.hex(32)
          session = Ticketing::ScannerSession.create!(
            scanner_invitation: locked,
            scanner_device_assignment: assignment_result.value,
            token_digest: Ticketing::ScannerSession.token_digest_for(token: session_token),
            idempotency_key_digest: key_digest,
            request_digest:,
            expires_at: locked.ends_at
          )
          locked.record_audit!(
            "ticketing.scanner_invitation.paired",
            audited_changes: { status: [ previous_status, locked.status ] },
            metadata: {
              invitation_id: locked.id,
              paired_user_id: operator.id,
              event_staff_assignment_id: staff_assignment.id,
              scanner_device_id: device_result.value.device.id,
              scanner_device_assignment_id: assignment_result.value.id,
              pairing_method:
            }
          )
          result = success(Result.new(
            invitation: locked,
            session:,
            scanner_session_token: session_token,
            replayed: false
          ))
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(error(:pairing_invalid, :unauthorized))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:pairing_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:pairing_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :pairing_token, :pairing_code, :pairing_method, :installation_id,
                  :device_name, :ip_address, :idempotency_key_input, :at, :cache

      def idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def valid_input?
        return false unless installation_id.match?(INSTALLATION_ID_PATTERN)
        return false unless pairing_method.in?(Ticketing::ScannerInvitation::PAIRING_METHODS)
        return false unless pairing_token.present? ^ pairing_code.present?

        if pairing_token.present?
          pairing_token.match?(/\A[0-9a-f]{64}\z/) && pairing_method.in?(%w[sms_link organizer_qr])
        else
          pairing_code.match?(/\A\d{6}\z/) && pairing_method == "short_code"
        end
      end

      def pairing_key_digest(key)
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-pair-idempotency",
          value: key.digest
        )
      end

      def pairing_request_digest
        capability_digest = if pairing_token.present?
          Ticketing::ScannerInvitation.token_digest_for(token: pairing_token)
        else
          Ticketing::ScannerInvitation.pairing_code_digest_for(code: pairing_code)
        end
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-pair-request",
          value: ActiveSupport::JSON.encode(
            method: pairing_method,
            capability_digest:,
            installation_id:,
            device_name:
          )
        )
      end

      def replay_session(key_digest:, request_digest:)
        session = Ticketing::ScannerSession.includes(
          scanner_invitation: :event,
          scanner_device_assignment: [ :scanner_device, :event_staff_assignment ]
        ).find_by(idempotency_key_digest: key_digest)
        return unless session
        return failure(error(:idempotency_conflict, :conflict)) unless session.request_digest == request_digest

        success(Result.new(
          invitation: session.scanner_invitation,
          session:,
          scanner_session_token: nil,
          replayed: true
        ))
      end

      def code_attempt_limited?
        installation_key = throttle_key("installation", installation_id)
        ip_key = throttle_key("ip", ip_address.presence || "unknown")
        installation_count = increment_counter(installation_key)
        ip_count = increment_counter(ip_key)
        installation_count > CODE_ATTEMPT_LIMIT || ip_count > IP_CODE_ATTEMPT_LIMIT
      end

      def throttle_key(scope, value)
        digest = Core::KeyedDigest.digest(namespace: "ticketing/scanner-pair/#{scope}", value:)
        "ticketing/scanner/pair/#{scope}/#{digest}"
      end

      def increment_counter(key)
        count = cache.increment(key, 1, expires_in: CODE_ATTEMPT_WINDOW)
        return count if count

        cache.write(key, 1, expires_in: CODE_ATTEMPT_WINDOW)
        1
      end

      def find_invitation
        if pairing_token.present?
          ScannerInvitation.find_by(token_digest: ScannerInvitation.token_digest_for(token: pairing_token))
        else
          ScannerInvitation.pairable.find_by(
            pairing_code_digest: ScannerInvitation.pairing_code_digest_for(code: pairing_code)
          )
        end
      end

      def current_capability?(invitation)
        expected = if pairing_token.present?
          ScannerInvitation.token_digest_for(token: pairing_token)
        else
          ScannerInvitation.pairing_code_digest_for(code: pairing_code)
        end
        actual = pairing_token.present? ? invitation.token_digest : invitation.pairing_code_digest
        actual.present? && ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      rescue ArgumentError
        false
      end

      def capability_unexpired?(invitation)
        return true if pairing_token.present?

        invitation.pairing_code_expires_at.present? && invitation.pairing_code_expires_at > at
      end

      def existing_staff_assignment(invitation, operator)
        Events::EventStaffAssignment.active.find_by(
          id: invitation.event_staff_assignment_id,
          event_id: invitation.event_id,
          user_id: operator.id,
          role: "scanner"
        )
      end

      def delegated_grant(invitation)
        Events::StaffAssignments::DelegatedGrant.new(
          event_id: invitation.event_id,
          role: "scanner",
          grantor_id: invitation.created_by_id,
          source_type: invitation.class.name,
          source_id: invitation.id,
          issued_at: invitation.created_at
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
