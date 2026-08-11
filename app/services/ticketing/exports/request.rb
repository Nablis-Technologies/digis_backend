# frozen_string_literal: true

module Ticketing
  module Exports
    # Creates one authenticated, idempotent export request and its dispatch evidence.
    class Request < Core::BaseService
      PURPOSE = "attendee_export_request"
      MAX_EXPIRY = 24.hours

      def initialize(actor:, event:, session_jti:, raw_proof: nil, idempotency_key:, row_mode:, field_keys:, filters:, reason_code:)
        @actor = actor
        @event = event
        @session_jti = session_jti
        @raw_proof = raw_proof
        @idempotency_key = idempotency_key
        @row_mode = row_mode.to_s
        @field_keys = field_keys
        @filters = filters
        @reason_code = reason_code.to_s
      end

      def call
        @digest_key_version = Core::AttendeeExportDigest.current_version
        @idempotency_key_digest = idempotency_digest

        AttendeeExport.transaction do
          Core::Database::AdvisoryLock.acquire_all!(
            [ "registration-privacy-event", event.id ],
            *idempotency_digests.map { |digest| [ "ticketing-attendee-export-idempotency", digest ] }
          )
          locked_event = Events::Event.find(event.id)
          bounds_error = request_bounds_error
          return failure(bounds_error) if bounds_error

          candidate = build_candidate(locked_event)

          validation_error = validate_candidate(candidate, locked_event)
          return failure(validation_error) if validation_error

          existing = AttendeeExport.where(idempotency_key_digest: idempotency_digests).lock.first
          return replay_result(existing, candidate) if existing

          proof_result = consume_proof
          return proof_result if proof_result.failure?

          candidate.save!
          record_audit(candidate)
          publish_request(candidate)
          success(candidate)
        end
      rescue ArgumentError => error
        failure(
          business_error(
            "invalid_idempotency_key",
            I18n.t("ticketing.attendee_exports.errors.invalid_idempotency_key")
          )
        )
      rescue Core::Audit::Record::ReplayConflict, Core::Outbox::Publish::IdempotencyConflict
        failure(business_error("idempotency_conflict", I18n.t("idempotency.conflict"), status: 409))
      rescue ActiveRecord::RecordInvalid => error
        failure(invalid_candidate_error(error.record))
      end

      private

      attr_reader :actor, :event, :session_jti, :raw_proof, :idempotency_key,
                  :row_mode, :field_keys, :filters, :reason_code, :idempotency_key_digest,
                  :digest_key_version

      def idempotency_digest(version: digest_key_version)
        Core::AttendeeExportDigest.digest(
          namespace: "ticketing/attendee_export/idempotency/#{actor.id}",
          value: Core::IdempotencyKey.new(idempotency_key).to_s,
          version:
        )
      end

      def idempotency_digests
        Core::AttendeeExportDigest.versions.map { |version| idempotency_digest(version:) }
      end

      def build_candidate(locked_event)
        now = Time.current
        normalized_filters = canonical_value(filters || {})
        normalized_fields = field_keys

        AttendeeExport.new(
          event: locked_event,
          requested_by: actor,
          status: "pending",
          row_mode:,
          format_version: "csv_v1",
          field_keys: normalized_fields,
          filters: normalized_filters,
          field_set_digest: digest_for(
            "field_set", { row_mode:, field_keys: normalized_fields }, sort_arrays: false
          ),
          filter_digest: digest_for("filters", normalized_filters),
          reason_code:,
          data_cutoff_at: now,
          expires_at: now + MAX_EXPIRY,
          idempotency_key_digest:,
          request_fingerprint: request_fingerprint(locked_event, normalized_fields, normalized_filters),
          digest_key_version:,
          attempt_count: 0,
          lock_version: 0
        )
      end

      def validate_candidate(candidate, locked_event)
        registry_result = FieldRegistry.resolve(
          event: locked_event,
          selectors: candidate.field_keys,
          row_mode: candidate.row_mode
        )
        return registry_result.error if registry_result.failure?
        return invalid_candidate_error(candidate) unless candidate.valid?
        return not_authorized_error unless AttendeeExportPolicy.new(actor, candidate).create?

        nil
      end

      def request_bounds_error
        return invalid_field_keys_error unless field_keys.is_a?(Array) &&
          field_keys.length <= 100 && field_keys.uniq.length == field_keys.length
        return invalid_filters_error unless bounded_filters?

        nil
      end

      def bounded_filters?
        return true if filters.nil?
        if filters.is_a?(ActionController::Parameters)
          return filters.each_pair.all? { |_key, values| bounded_filter_values?(values) }
        end

        raw_filters = filters
        return false unless raw_filters.is_a?(Hash)

        raw_filters.values.all? { |values| bounded_filter_values?(values) }
      end

      def bounded_filter_values?(values)
        !values.is_a?(Array) || (values.length <= 100 && values.uniq.length == values.length)
      end

      def replay_result(existing, candidate)
        expected_fingerprint = request_fingerprint(
          candidate.event,
          candidate.field_keys,
          candidate.filters,
          version: existing.digest_key_version
        )
        return success(existing) if existing.request_fingerprint == expected_fingerprint &&
          existing.event_id == candidate.event_id && existing.requested_by_id == candidate.requested_by_id

        failure(business_error("idempotency_conflict", I18n.t("idempotency.conflict"), status: 409))
      end

      def consume_proof
        Core::Reauthentication::Consume.call(
          user: actor,
          session_jti:,
          purpose: PURPOSE,
          raw_proof:
        )
      end

      def record_audit(export)
        result = Core::Audit::Record.call(
          audit_key: audit_key,
          action: "ticketing.attendee_export.requested",
          auditable_type: export.class.name,
          auditable_id: export.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { status: [ nil, export.status ] },
          metadata: {
            event_id: export.event_id,
            row_mode: export.row_mode,
            reason_code: export.reason_code,
            field_set_digest: export.field_set_digest,
            filter_digest: export.filter_digest,
            request_fingerprint: export.request_fingerprint,
            idempotency_key_digest: export.idempotency_key_digest,
            digest_key_version: export.digest_key_version
          }
        )
        raise result.error if result.failure?
      end

      def publish_request(export)
        result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.attendee_export.requested",
          aggregate: export,
          payload: { attendee_export_id: export.id },
          idempotency_key: "ticketing-attendee-export-requested:#{export.id}"
        )
        raise result.error if result.failure?
      end

      def audit_key
        "ticketing-attendee-export-request:#{idempotency_key_digest}"
      end

      def request_fingerprint(locked_event, normalized_fields, normalized_filters, version: digest_key_version)
        digest_for(
          "request_fingerprint",
          {
            actor_id: actor.id,
            event_id: locked_event.id,
            row_mode:,
            field_keys: normalized_fields,
            filters: normalized_filters,
            reason_code:
          },
          version:,
          sort_arrays: false
        )
      end

      def digest_for(purpose, value, version: digest_key_version, sort_arrays: true)
        Core::AttendeeExportDigest.digest(
          namespace: "ticketing/attendee_export/#{purpose}",
          value: ActiveSupport::JSON.encode(canonical_value(value, sort_arrays:)),
          version:
        )
      end

      def canonical_value(value, sort_arrays: true)
        case value
        when ActionController::Parameters
          canonical_value(value.to_unsafe_h, sort_arrays:)
        when Hash
          value.to_h.stringify_keys.keys.sort.each_with_object({}) do |key, result|
            child = value.key?(key) ? value[key] : value[key.to_sym]
            result[key] = canonical_value(child, sort_arrays:)
          end
        when Array
          values = value.map { |nested| canonical_value(nested, sort_arrays:) }
          sort_arrays ? values.sort_by { |nested| ActiveSupport::JSON.encode(nested) } : values
        else
          value
        end
      end

      def invalid_candidate_error(candidate)
        return invalid_filters_error if candidate.errors.key?(:filters)

        business_error(
          "invalid_request",
          I18n.t("ticketing.attendee_exports.errors.invalid_request"),
          errors: candidate.errors.to_hash
        )
      end

      def invalid_filters_error
        business_error(
          "invalid_filters",
          I18n.t("ticketing.attendee_exports.errors.invalid_filters")
        )
      end

      def invalid_field_keys_error
        business_error(
          "invalid_field_keys",
          I18n.t("ticketing.attendee_exports.errors.invalid_field_keys")
        )
      end

      def not_authorized_error
        business_error(
          "not_authorized",
          I18n.t("authorization.errors.unauthorized"),
          status: :forbidden
        )
      end

      def business_error(code, message, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(message, code:, status:, errors:)
      end
    end
  end
end
