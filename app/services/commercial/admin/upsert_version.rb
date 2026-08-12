# frozen_string_literal: true

module Commercial
  module Admin
    # Creates or edits a draft fee version and its nested definition rows. The
    # definition digest is recalculated after the component graph is persisted;
    # approved and later versions are never accepted by this command.
    class UpsertVersion < Core::BaseService
      include Commercial::Governance::CommandSupport

      COMPONENT_ATTRIBUTES = %i[
        component_type calculation_type charged_to organizer_payer_choice funded_by basis_type rate_bps
        refund_policy offset_component_type event_product_id product_type sale_context provider payment_method
        sales_channel currency label
      ].freeze
      AMOUNT_ATTRIBUTES = %i[currency fixed_amount_minor minimum_minor maximum_minor].freeze
      TIER_ATTRIBUTES = %i[position metric_type window_type currency starts_at_value rate_bps fixed_amount_minor minimum_minor maximum_minor].freeze

      def initialize(version:, fee_schedule:, actor:, attributes:, idempotency_key:, create:)
        @version = version
        @fee_schedule = fee_schedule
        @actor = actor
        @attributes = attributes.to_h.deep_symbolize_keys
        @idempotency_key = idempotency_key
        @create = create
      end

      def call
        return failure(unauthorized_error("commercial.draft")) unless actor&.has_permission?("commercial.draft")

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_schedule = Commercial::FeeSchedule.lock.find(fee_schedule.id)
          replay = replay_version
          return replay if replay

          prepare_version!(locked_schedule)
          replace_definition!
          refresh_digest!
          record_transition!
          success(version.reload)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          governance_error(
            "invalid_record", code: "invalid_record", errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :version, :fee_schedule, :actor, :attributes, :idempotency_key, :create,
        :key_digest, :request_fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        verb = create ? "create" : "update"
        @key_digest = idempotency_digest("admin-fee-schedule-version-#{verb}", idempotency_key)
        @request_fingerprint = fingerprint_for(
          action: verb, fee_schedule_id: fee_schedule.id, version_id: version.id,
          actor_id: actor.id, attributes:
        )
      end

      def audit_key
        "commercial-admin-fee-schedule-version-#{create ? "create" : "update"}-#{key_digest}"
      end

      def replay_version
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        status = replay_status(audit_key:, actor:, fingerprint: request_fingerprint)
        return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if status == :conflict

        target = Commercial::FeeScheduleVersion.find_by(id: audit.metadata["record_id"])
        return failure(governance_error("replay_not_found", code: "replay_not_found")) unless target

        success(target)
      end

      def prepare_version!(locked_schedule)
        if create
          next_version = locked_schedule.fee_schedule_versions.lock.order(version: :desc).pick(:version).to_i + 1
          version.assign_attributes(
            fee_schedule: locked_schedule,
            version: next_version,
            status: "draft",
            definition_digest: "0" * 64
          )
        else
          return if version.status.in?(%w[draft simulated])

          raise governance_error("state_conflict", code: "state_conflict")
        end

        version.assign_attributes(version_attributes.merge(status: "draft")) unless create
        version.assign_attributes(version_attributes) if create
        version.save!
      end

      def version_attributes
        attributes.slice(
          :supersedes_version_id, :acceptance_policy, :grandfather_until,
          :effective_from, :effective_until, :legal_document_version_id
        )
      end

      def replace_definition!
        return unless attributes.key?(:components)

        version.fee_components.destroy_all unless create
        Array(attributes[:components]).each do |component_attributes|
          create_component!(component_attributes.deep_symbolize_keys)
        end
      end

      def create_component!(component_attributes)
        component = version.fee_components.create!(component_attributes.slice(*COMPONENT_ATTRIBUTES))
        Array(component_attributes[:amounts]).each do |amount_attributes|
          component.fee_amounts.create!(amount_attributes.slice(*AMOUNT_ATTRIBUTES))
        end
        Array(component_attributes[:tiers]).each do |tier_attributes|
          component.fee_tiers.create!(tier_attributes.slice(*TIER_ATTRIBUTES))
        end
      end

      def refresh_digest!
        canonical = Commercial::Definitions::Canonicalize.call(version:)
        raise canonical.error if canonical.failure?

        version.update!(definition_digest: canonical.value.digest)
      end

      def record_transition!
        action_name = create ? "created" : "updated"
        super(
          target: version,
          actor:,
          audit_key:,
          action: "commercial.fee_schedule_version.#{action_name}",
          audited_changes: { "definition_digest" => version.definition_digest },
          metadata: { "record_id" => version.id, "request_fingerprint" => request_fingerprint },
          topic: "commercial",
          event_type: "commercial.fee_schedule_version.#{action_name}",
          payload: { fee_schedule_version_id: version.id, definition_digest: version.definition_digest }
        )
      end
    end
  end
end
