# frozen_string_literal: true

module Ticketing
  module Admissions
    # Resolves a signed credential and consumes all of its admission slots in
    # one server transaction. Ticket and slot row locks serialize competing
    # scans before the active-use ceiling and monotonic usage numbers are read.
    class Consume < Core::BaseService
      DECISION_RESULTS = {
        invalid_claims: "invalid",
        expired: "invalid",
        wrong_event: "wrong_channel",
        wrong_access: "wrong_channel",
        outside_window: "wrong_date",
        zone_required: "wrong_zone",
        wrong_zone: "wrong_zone",
        package_dead: "revoked",
        package_suspended: "revoked",
        revoked_generation: "revoked",
        revoked_credential: "revoked",
        already_used: "duplicate"
      }.freeze

      def initialize(
        claims:, product_access:, assignment:, access_zone: nil, scan_upload: nil, client_scan_id:, scanned_at:,
        lookup_via: "qr", reason_code: nil, identity_check: nil, identity_checked_by: nil,
        now: Time.current, received_at: Time.current, overrides_checkin_log: nil,
        identity_override_by: nil, identity_override_reason: nil, identity_overridden_at: nil
      )
        @claims = normalize_claims(claims)
        @product_access_id = product_access.id
        @assignment_id = assignment.id
        @access_zone_id = access_zone&.id
        @scan_upload = scan_upload
        @client_scan_id = client_scan_id
        @scanned_at = scanned_at
        @lookup_via = lookup_via
        @reason_code = reason_code
        @identity_check = identity_check
        @identity_checked_by = identity_checked_by
        @now = now
        @received_at = received_at
        @overrides_checkin_log = overrides_checkin_log
        @identity_override_by = identity_override_by
        @identity_override_reason = identity_override_reason
        @identity_overridden_at = identity_overridden_at
      end

      def call
        return failure(error(:invalid_claims, :unprocessable_entity)) unless @claims

        outcome = Ticketing::ApplicationRecord.transaction { consume_locked }
        return outcome if outcome.is_a?(Core::BaseService::Result)

        success(outcome)
      rescue ActiveRecord::RecordNotUnique
        existing = existing_checkin
        return success(existing) if existing

        failure(error(:admission_record_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          error(
            :admission_record_invalid,
            :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :claims

      def consume_locked
        existing = Ticketing::CheckinLog.includes(:admission_uses).find_by(client_scan_id: @client_scan_id)
        return existing if existing

        event_id = Ticketing::Ticket.where(id: claims.tid).pick(:event_id)
        return failure(error(:ticket_not_found, :not_found)) unless event_id

        event = Events::Event.lock.find(event_id)
        return failure(error(:event_cancelled, :conflict)) if event.status == "cancelled"

        ticket = Ticketing::Ticket.includes(:event, :revocation, event_product: :ticket_type).lock.find_by(id: claims.tid)
        return failure(error(:ticket_not_found, :not_found)) unless ticket
        ticket.event = event

        product_access = Catalog::ProductAccess.lock.find_by(id: @product_access_id)
        return failure(error(:product_access_not_found, :not_found)) unless product_access

        assignment = Ticketing::ScannerDeviceAssignment.lock.find_by(id: @assignment_id)
        return failure(error(:assignment_not_found, :unprocessable_entity)) unless assignment

        access_zone = Events::AccessZone.find_by(id: @access_zone_id) if @access_zone_id
        return failure(error(:zone_not_found, :unprocessable_entity)) if @access_zone_id && access_zone.nil?

        return failure(error(:assignment_event_mismatch, :unprocessable_entity)) unless assignment.event_id == ticket.event_id
        return failure(error(:product_access_event_mismatch, :unprocessable_entity)) unless product_access.event_date.event_id == ticket.event_id

        generation = Ticketing::CredentialGeneration.lock.find_by(id: ticket.current_credential_generation_id)
        credential = Ticketing::Credential.includes(:credential_generation, :credential_revocation)
          .lock.find_by(id: claims.cid, ticket_id: ticket.id)
        return failure(error(:credential_not_found, :not_found)) unless generation && credential

        slots = lock_claimed_slots(ticket)
        unless claims_match_records?(ticket, generation, credential, slots)
          return record_decision(
            ticket:,
            credential:,
            product_access:,
            assignment:,
            access_zone:,
            event_date: product_access.event_date,
            result: "version_mismatch",
            identity: identity_snapshot(ticket)
          )
        end

        locked_uses = lock_uses(slots, product_access)
        usage_policy = Ticketing::Admissions::UsagePolicy.new(
          admission_slots: slots,
          product_access:,
          locked_uses:
        )

        zone_result = Ticketing::Zones::AuthorizeAdmission.call(
          assignment:,
          product_access:,
          access_zone:,
          now: @now
        )
        unless zone_result.success?
          return record_decision(
            ticket:,
            credential:,
            product_access:,
            assignment:,
            access_zone:,
            event_date: product_access.event_date,
            result: DECISION_RESULTS.fetch(zone_result.error.code.to_sym, "wrong_zone"),
            identity: identity_snapshot(ticket)
          )
        end

        identity = identity_snapshot(ticket)
        return identity if identity.is_a?(Core::BaseService::Result)

        validator = validator_for(
          ticket:,
          generation:,
          credential:,
          product_access:,
          assignment:,
          access_zone:,
          slots:,
          usage_policy:
        )
        decision = validator.value
        return record_decision(
          ticket:,
          credential:,
          product_access:,
          assignment:,
          access_zone:,
          event_date: product_access.event_date,
          result: DECISION_RESULTS.fetch(decision.to_sym, "invalid"),
          identity:
        ) unless decision.to_s == "valid"

        if identity.fetch(:identity_check_result) == "mismatch" && @overrides_checkin_log.nil?
          return record_decision(
            ticket:,
            credential:,
            product_access:,
            assignment:,
            access_zone:,
            event_date: product_access.event_date,
            result: "identity_mismatch",
            identity:
          )
        end

        return record_decision(
          ticket:,
          credential:,
          product_access:,
          assignment:,
          access_zone:,
          event_date: product_access.event_date,
          result: "duplicate",
          identity:
        ) unless usage_policy.eligible?

        attempt = record_attempt(
          ticket:,
          credential:,
          product_access:,
          assignment:,
          access_zone:,
          event_date: product_access.event_date,
          result: "success",
          identity:
        )
        return attempt if attempt.is_a?(Core::BaseService::Result)

        slots.each do |slot|
          Ticketing::AdmissionUse.create!(
            admission_slot: slot,
            product_access:,
            credential:,
            checkin_log: attempt,
            usage_number: usage_policy.next_usage_number(slot),
            used_at: @scanned_at
          )
        end

        attempt
      end

      def lock_claimed_slots(ticket)
        Ticketing::AdmissionSlot.where(ticket_id: ticket.id, position: claims.slots)
          .order(:position, :id).lock.to_a
      end

      def lock_uses(slots, product_access)
        Ticketing::AdmissionUse.where(
          admission_slot_id: slots.map(&:id), product_access_id: product_access.id
        ).includes(:reversal).lock.to_a
      end

      def claims_match_records?(ticket, generation, credential, slots)
        # Mutable activation/revocation state belongs to Validator; this check
        # only proves that the signed claim resolves to the same immutable
        # ticket, generation, credential, and slot set.
        claims.tid == ticket.id.to_s &&
          claims.eid == ticket.event_id.to_s &&
          claims.v == generation.version &&
          claims.mode == (generation.mode == "group" ? "group" : "individual") &&
          claims.entry_limit == credential.entry_limit &&
          claims.slots.sort == credential.slot_positions.sort &&
          slots.map(&:position).sort == claims.slots.sort &&
          credential.credential_generation_id == generation.id &&
          ticket.current_credential_generation_id == generation.id
      end

      def validator_for(ticket:, generation:, credential:, product_access:, assignment:, access_zone:, slots:, usage_policy:)
        event_date = product_access.event_date
        active_zone_ids = Events::AccessZone.where(
          event_id: ticket.event_id, type: product_access.type, active: true
        ).where(event_date_id: [ nil, event_date.id ]).pluck(:id)
        assigned_zone_ids = Ticketing::ScannerAssignmentZone.where(
          scanner_device_assignment_id: assignment.id
        ).pluck(:access_zone_id)

        slots_by_position = slots.index_by(&:position)

        Ticketing::Credentials::Validator.call(
          claims:,
          event_id: ticket.event_id,
          product_access_id: product_access.id,
          open_at: event_date.starts_at + (product_access.opens_offset_seconds || 0),
          close_at: event_date.ends_at + (product_access.closes_offset_seconds || 0),
          now: @now,
          allowed_zone_ids: active_zone_ids,
          access_zone_id: access_zone&.id,
          assigned_zone_ids:,
          package_dead: ticket.package_dead?,
          package_suspended: ticket.package_suspended?,
          revoked_through_version: [
            ticket.revocation&.revoked_through_version.to_i,
            generation.status == "revoked" ? generation.version : 0
          ].max,
          credential_revoked: credential.status != "active" || credential.credential_revocation.present?,
          usage_limit: product_access.usage_limit,
          active_use_counts: claims.slots.index_with do |position|
            usage_policy.active_use_count(slots_by_position.fetch(position))
          end
        )
      end

      def identity_snapshot(ticket)
        expected = ticket.event_product.ticket_type.entry_validation_mode
        requested = normalize_identity_check

        if expected == "qr" && requested.nil?
          return { identity_check_result: "not_required", identity_checked_by: nil }
        end
        return failure(error(:identity_check_required, :unprocessable_entity)) if requested.nil?
        return failure(error(:identity_check_invalid, :unprocessable_entity)) unless requested.in?(%w[matched mismatch])
        return failure(error(:identity_checker_required, :unprocessable_entity)) unless @identity_checked_by

        { identity_check_result: requested, identity_checked_by: @identity_checked_by }
      end

      def normalize_identity_check
        value = @identity_check.respond_to?(:to_h) ? @identity_check.to_h[:result] || @identity_check.to_h["result"] : @identity_check
        value.to_s.presence
      end

      def record_decision(ticket:, credential:, product_access:, assignment:, access_zone:, event_date:, result:, identity:)
        return identity if identity.is_a?(Core::BaseService::Result)

        if result == "identity_mismatch"
          mismatch = Ticketing::Checkins::RecordIdentityMismatch.call(
            ticket:,
            credential:,
            credential_version: claims.v,
            product_access:,
            event_date:,
            assignment:,
            scan_upload: @scan_upload,
            client_scan_id: @client_scan_id,
            scanned_at: @scanned_at,
            lookup_via: @lookup_via,
            access_zone:,
            reason_code: @reason_code,
            identity_checked_by: identity.fetch(:identity_checked_by),
            received_at: @received_at
          )
          return mismatch if mismatch.failure?

          return mismatch.value
        end

        record_attempt(
          ticket:,
          credential:,
          product_access:,
          assignment:,
          access_zone:,
          event_date:,
          result:,
          identity:
        )
      end

      def record_attempt(ticket:, credential:, product_access:, assignment:, access_zone:, event_date:, result:, identity:)
        override_attributes = result == "success" ? {
          overrides_checkin_log: @overrides_checkin_log,
          identity_override_by: @identity_override_by,
          identity_override_reason: @identity_override_reason,
          identity_overridden_at: @identity_overridden_at
        } : {}

        attempt = Ticketing::Checkins::RecordAttempt.call(
          ticket:,
          credential:,
          product_access:,
          credential_version: claims.v,
          event_date:,
          assignment:,
          access_zone:,
          scan_upload: @scan_upload,
          client_scan_id: @client_scan_id,
          result:,
          scanned_at: @scanned_at,
          lookup_via: @lookup_via,
          reason_code: @reason_code,
          identity_check_result: identity.fetch(:identity_check_result),
          identity_checked_by: identity.fetch(:identity_checked_by),
          received_at: @received_at,
          **override_attributes
        )
        return attempt if attempt.failure?

        attempt.value
      end

      def existing_checkin
        Ticketing::CheckinLog.includes(:admission_uses).find_by(client_scan_id: @client_scan_id)
      end

      def normalize_claims(value)
        return value if value.is_a?(Ticketing::CredentialClaims)

        Ticketing::CredentialClaims.from_h(value)
      rescue ArgumentError, NoMethodError, TypeError
        nil
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
