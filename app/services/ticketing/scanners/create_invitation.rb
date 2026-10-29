# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Creates a durable event-scoped scanner delegation and delivery event.
    # The creator's permission is checked now; a later role removal does not
    # revoke this invitation unless an organizer explicitly revokes it.
    class CreateInvitation < Core::BaseService
      Result = Data.define(:record, :token, :pairing_code, :replayed) do
        def replayed? = replayed
      end

      PAIRING_CODE_TTL = 10.minutes
      CODE_GENERATION_ATTEMPTS = 10

      def initialize(event:, actor:, phone:, label: nil, note: nil, zone_mode: "all_current_zones",
        zone_ids: [], starts_at: nil, ends_at: nil, expires_at: nil, idempotency_key:, at: Time.current)
        @event = event
        @actor = actor
        @phone_input = phone
        @label = label.to_s.strip.presence
        @note = note.to_s.strip.presence
        @zone_mode = zone_mode.to_s
        @zone_ids = Array(zone_ids).compact.map(&:to_s).uniq.sort
        @starts_at_input = starts_at
        @ends_at_input = ends_at
        @expires_at_input = expires_at
        @idempotency_key_input = idempotency_key
        @at = at
      end

      def call
        key = build_idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(error(:invitation_forbidden, :forbidden)) unless authorized?

        normalized_phone = Core::PhoneIdentity::ResolveOrCreate.normalize(phone_input)
        return failure(error(:phone_identity_invalid, :unprocessable_entity)) if normalized_phone.blank?

        window = access_window
        return failure(window) if window.is_a?(Core::BusinessError)

        zone_error = validate_zones
        return failure(zone_error) if zone_error

        key_digest = create_key_digest(key)
        request_digest = creation_request_digest(normalized_phone:, window:)
        result = nil

        ActiveRecord::Base.transaction do
          Core::Database::AdvisoryLock.acquire!("ticketing-scanner-invitation-create", event.id, actor.id, key.digest)
          event.lock!

          existing = ScannerInvitation.lock.find_by(create_idempotency_key_digest: key_digest)
          if existing
            result = replay(existing, request_digest)
            next
          end

          phone_digest = ScannerInvitation.phone_digest_for(event_id: event.id, phone: normalized_phone)
          if ScannerInvitation.live.exists?(event_id: event.id, phone_digest:)
            result = failure(error(:scanner_invitation_exists, :conflict))
            next
          end

          Core::Database::AdvisoryLock.acquire!("ticketing-scanner-pairing-code")
          token = SecureRandom.hex(32)
          pairing_code, pairing_code_digest = generate_pairing_code
          invitation = ScannerInvitation.new(
            event:,
            organization: event.organization,
            created_by: actor,
            phone: normalized_phone,
            phone_digest:,
            display_label: label,
            organizer_note: note,
            token:,
            token_digest: ScannerInvitation.token_digest_for(token:),
            pairing_code: pairing_code,
            pairing_code_digest:,
            status: "pending",
            delivery_status: "queued",
            delivery_revision: 1,
            zone_mode:,
            selected_zone_ids: zone_ids,
            starts_at: window.fetch(:starts_at),
            ends_at: window.fetch(:ends_at),
            expires_at: window.fetch(:expires_at),
            pairing_code_expires_at: [ at + PAIRING_CODE_TTL, window.fetch(:expires_at) ].min,
            create_idempotency_key_digest: key_digest,
            create_request_digest: request_digest
          )

          unless invitation.valid?
            result = failure(Core::BusinessError.new(
              invitation.errors.full_messages.to_sentence,
              code: "scanner_invitation_invalid",
              status: :unprocessable_entity,
              errors: invitation.errors.to_hash
            ))
            next
          end

          invitation.save!
          record_creation_audit!(invitation)
          publish_delivery!(invitation)
          result = success(Result.new(record: invitation, token:, pairing_code:, replayed: false))
        end

        result
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:scanner_invitation_exists, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.scanner_invitation_invalid"),
          code: "scanner_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :event, :actor, :phone_input, :label, :note, :zone_mode, :zone_ids,
                  :starts_at_input, :ends_at_input, :expires_at_input, :idempotency_key_input, :at

      def build_idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def authorized?
        Events::AuthorizationResolver.can_assign?(actor, event, "scanner") &&
          !event.status.in?(%w[cancelled completed])
      end

      def access_window
        scheduled_end = event.event_dates.where(status: "scheduled").maximum(:ends_at)
        default_end = scheduled_end&.+(6.hours)
        starts_at = parsed_input(starts_at_input, at)
        ends_at = parsed_input(ends_at_input, default_end)
        expires_at = parsed_input(expires_at_input, ends_at)

        return error(:scanner_window_invalid, :unprocessable_entity) if [ starts_at, ends_at, expires_at ].any?(&:nil?)
        return error(:scanner_window_invalid, :unprocessable_entity) unless starts_at < ends_at
        return error(:scanner_window_invalid, :unprocessable_entity) unless at < expires_at && expires_at <= ends_at

        { starts_at:, ends_at:, expires_at: }
      end

      def parse_time(value)
        return value.in_time_zone if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def parsed_input(value, default)
        parsed = parse_time(value)
        return parsed if parsed.present?
        return default if value.blank?

        nil
      end

      def validate_zones
        return error(:zone_invalid, :unprocessable_entity) unless zone_mode.in?(ScannerInvitation::ZONE_MODES)
        return error(:zone_invalid, :unprocessable_entity) if zone_mode == "all_current_zones" && zone_ids.any?
        return if zone_ids.empty?

        zones_count = Events::AccessZone.where(id: zone_ids, event_id: event.id, active: true).count
        error(:zone_invalid, :unprocessable_entity) unless zones_count == zone_ids.length
      end

      def create_key_digest(key)
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-invitation-create/#{event.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def creation_request_digest(normalized_phone:, window:)
        payload = {
          event_id: event.id,
          actor_id: actor.id,
          phone: normalized_phone,
          label:,
          note:,
          zone_mode:,
          zone_ids:,
          starts_at: window.fetch(:starts_at).iso8601(6),
          ends_at: window.fetch(:ends_at).iso8601(6),
          expires_at: window.fetch(:expires_at).iso8601(6)
        }
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-invitation-create-request",
          value: ActiveSupport::JSON.encode(canonicalize(payload))
        )
      end

      def canonicalize(value)
        case value
        when Hash
          value.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonicalize(nested) }
        when Array
          value.map { |nested| canonicalize(nested) }
        else
          value.as_json
        end
      end

      def replay(invitation, request_digest)
        return failure(error(:idempotency_conflict, :conflict)) unless invitation.create_request_digest == request_digest

        code = invitation.pairing_code if invitation.pairing_code_expires_at.present? &&
          invitation.pairing_code_expires_at > at
        success(Result.new(
          record: invitation,
          token: invitation.token,
          pairing_code: code,
          replayed: true
        ))
      end

      def generate_pairing_code
        CODE_GENERATION_ATTEMPTS.times do
          code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
          digest = ScannerInvitation.pairing_code_digest_for(code:)
          return [ code, digest ] unless ScannerInvitation.pairable.exists?(pairing_code_digest: digest)
        end

        raise Core::Error, I18n.t("ticketing.scanner.errors.pairing_code_unavailable")
      end

      def record_creation_audit!(invitation)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-scanner-invitation-created-#{invitation.id}",
          action: "ticketing.scanner_invitation.created",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { event_id: event.id, status: "pending" },
          metadata: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision }
        )
        raise result.error if result.failure?
      end

      def publish_delivery!(invitation)
        idempotency_key = Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-invitation-delivery",
          value: "#{invitation.id}:#{invitation.delivery_revision}"
        )
        result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.scanner_invitation.delivery_requested",
          aggregate: invitation,
          payload: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision },
          idempotency_key:
        )
        raise result.error if result.failure?
      end

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
