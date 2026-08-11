# frozen_string_literal: true

module Ticketing
  module PurchaseLimits
    # Grants one immutable, audited exception for a single registration.
    class GrantOverride < Core::BaseService
      include Support

      def initialize(registration:, approved_by:, additional_packages:, reason_code:, idempotency_key:)
        @registration = registration
        @approved_by = approved_by
        @additional_packages = additional_packages.to_i
        @reason_code = reason_code
        @idempotency_key = idempotency_key
      end

      def call
        validate_request!
        override = ActiveRecord::Base.transaction do
          ticket_type = Ticketing::TicketType.lock.find(registration.ticket_type_id)
          scope_event_date_id = limit_scope_for(ticket_type, registration)
          Core::Database::AdvisoryLock.acquire!("purchase-limit-override", registration.id)
          existing = PurchaseLimitOverride.lock.find_by(registration_id: registration.id)
          return success(replay_or_conflict(existing, scope_event_date_id)) if existing

          created = PurchaseLimitOverride.create!(
            registration:,
            ticket_type:,
            user: registration.user,
            scope_event_date_id:,
            additional_packages:,
            approved_by: approved_by,
            reason_code:,
            idempotency_key: key_digest
          )
          Core::Audit::Record.call(
            audit_key: "ticketing-purchase-limit-override-#{created.idempotency_key}",
            action: "ticketing.purchase_limit_override.granted",
            auditable_type: created.class.name,
            auditable_id: created.id,
            actor_type: approved_by.class.name,
            actor_id: approved_by.id,
            audited_changes: { additional_packages: [ nil, additional_packages ], reason_code: [ nil, reason_code ] },
            metadata: { registration_id: registration.id, ticket_type_id: ticket_type.id, scope_event_date_id: }
          ).value
          created
        end

        success(override)
      rescue Support::BusinessFailure => error
        error.result
      rescue ArgumentError => error
        failure(Core::BusinessError.new(error.message, code: "invalid_idempotency_key", status: :unprocessable_entity))
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::BusinessError.new(
          I18n.t("ticketing.purchase_limits.errors.override_invalid"),
          code: "invalid_override",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        ))
      rescue ActiveRecord::RecordNotUnique
        failure(conflict)
      end

      private

      attr_reader :registration, :approved_by, :additional_packages, :reason_code, :idempotency_key

      def validate_request!
        raise ArgumentError, I18n.t("ticketing.purchase_limits.errors.idempotency_key_required") if idempotency_key.blank?
        fail BusinessFailure, failure("purchase_limit_override_forbidden", "override_forbidden") unless authorized?
        fail BusinessFailure, failure("purchase_limit_override_invalid", "override_invalid") unless additional_packages.positive?
        return if PurchaseLimitOverride::REASON_CODES.include?(reason_code)

        fail BusinessFailure, failure("purchase_limit_override_reason_invalid", "reason_invalid")
      end

      def authorized?
        Events::AuthorizationResolver.can_manage_catalog?(approved_by, registration.event)
      end

      def replay_or_conflict(existing, scope_event_date_id)
        return existing if existing.idempotency_key == key_digest &&
          existing.additional_packages == additional_packages &&
          existing.reason_code == reason_code &&
          existing.scope_event_date_id == scope_event_date_id &&
          existing.approved_by_id == approved_by.id

        fail BusinessFailure, conflict
      end
    end
  end
end
