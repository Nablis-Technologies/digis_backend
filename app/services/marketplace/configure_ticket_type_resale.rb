# frozen_string_literal: true

require "digest"
require "json"

module Marketplace
  # Persists the organizer's ticket-type resale policy under a row lock. The
  # disabled state always clears cap fields, and fixed caps must match the
  # event settlement currency before the policy can be saved. The audit key
  # makes a retried API request replay the original result rather than repeat
  # policy-disable cleanup.
  class ConfigureTicketTypeResale < Core::BaseService
    ATTRIBUTES = %i[
      resale_enabled resale_cutoff_seconds_before_start resale_price_cap_type
      resale_fixed_cap_minor resale_fixed_cap_currency resale_percentage_cap_bps
      max_completed_resales
    ].freeze

    def initialize(ticket_type:, actor:, attributes:, idempotency_key:)
      @ticket_type = ticket_type
      @actor = actor
      @attributes = attributes.to_h.symbolize_keys.slice(*ATTRIBUTES)
      @idempotency_key = idempotency_key
      normalize_cap_attributes
    end

    def call
      key = Core::IdempotencyKey.new(idempotency_key)
      request_digest = Digest::SHA256.hexdigest(JSON.generate(attributes.deep_stringify_keys.sort.to_h))
      audit_key = "marketplace-resale-policy-#{ticket_type.id}-#{key.digest}"

      ActiveRecord::Base.transaction do
        locked_ticket_type = Ticketing::TicketType
          .includes(event_product: :event)
          .lock
          .find(@ticket_type.id)

        replay = Core::AuditLog.find_by(audit_key:)
        if replay
          return success(locked_ticket_type) if replay_matches?(replay, key:, request_digest:)

          return failure(idempotency_conflict)
        end

        before = locked_ticket_type.attributes.slice(*ATTRIBUTES.map(&:to_s))
        locked_ticket_type.assign_attributes(@attributes)
        clear_cap_fields_when_disabled(locked_ticket_type)

        return failure_for("resale_fixed_cap_currency_mismatch") if fixed_currency_mismatch?(locked_ticket_type)

        locked_ticket_type.save!
        cancel_open_listings!(locked_ticket_type) unless locked_ticket_type.resale_enabled
        record_policy_audit!(
          locked_ticket_type,
          before:,
          key:,
          request_digest:,
          audit_key:
        )
        success(locked_ticket_type)
      end
    rescue ArgumentError
      failure(idempotency_failure(:invalid_idempotency_key, :unprocessable_entity))
    rescue ActiveRecord::RecordNotFound
      failure_for("invalid_ticket_type")
    rescue ActiveRecord::RecordInvalid => error
      failure_for("invalid_resale_policy", errors: error.record.errors.to_hash)
    rescue Core::Error => error
      failure(error)
    end

    private

    attr_reader :actor, :attributes, :idempotency_key, :ticket_type

    def clear_cap_fields_when_disabled(ticket_type)
      return if ticket_type.resale_enabled

      ticket_type.resale_price_cap_type = nil
      ticket_type.resale_fixed_cap_minor = nil
      ticket_type.resale_fixed_cap_currency = nil
      ticket_type.resale_percentage_cap_bps = nil
    end

    def normalize_cap_attributes
      if attributes.key?(:resale_price_cap_type)
        attributes[:resale_price_cap_type] = attributes[:resale_price_cap_type].to_s.downcase.presence
      end
      if attributes.key?(:resale_fixed_cap_currency)
        attributes[:resale_fixed_cap_currency] = attributes[:resale_fixed_cap_currency].to_s.upcase.presence
      end
    end

    def fixed_currency_mismatch?(ticket_type)
      ticket_type.resale_enabled &&
        ticket_type.resale_price_cap_type == "fixed" &&
        ticket_type.resale_fixed_cap_currency.present? &&
        ticket_type.resale_fixed_cap_currency != ticket_type.event_product.event.currency
    end

    # Policy disablement must close every still-unsold offer in the same
    # transaction. Completed sales remain immutable, while repeated policy
    # writes are harmless because CancelListing treats cancellation as a
    # terminal idempotent transition.
    def cancel_open_listings!(ticket_type)
      ResaleListing.where(ticket_type_id: ticket_type.id, status: %w[active reserved]).lock.find_each do |listing|
        result = CancelListing.call(
          listing:,
          reason: "resale_policy_disabled",
          idempotency_key: "resale-policy-disabled-#{ticket_type.id}-#{listing.id}"
        )
        raise result.error if result.failure?
      end
    end

    def failure_for(code, errors: nil)
      failure Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"),
        code:,
        status: :unprocessable_entity,
        errors:
      )
    end

    def idempotency_failure(code, status)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.resale_policy_#{code}"), code: code.to_s, status:
      )
    end

    def idempotency_conflict
      idempotency_failure(:idempotency_conflict, :conflict)
    end

    def replay_matches?(audit, key:, request_digest:)
      audit.action == "marketplace.resale_policy.updated" &&
        audit.actor_id == actor.id &&
        audit.metadata["idempotency_key"] == key.to_s &&
        audit.metadata["request_digest"] == request_digest
    end

    def record_policy_audit!(locked_ticket_type, before:, key:, request_digest:, audit_key:)
      audit = Core::Audit::Record.call(
        audit_key:,
        action: "marketplace.resale_policy.updated",
        auditable_type: locked_ticket_type.class.name,
        auditable_id: locked_ticket_type.id,
        actor_type: actor.class.name,
        actor_id: actor.id,
        audited_changes: attribute_changes(before, locked_ticket_type.attributes),
        metadata: {
          ticket_type_id: locked_ticket_type.id,
          event_product_id: locked_ticket_type.event_product_id,
          idempotency_key: key.to_s,
          request_digest:
        }
      )
      raise audit.error if audit.failure?
    end

    def attribute_changes(before, after)
      before.each_with_object({}) do |(attribute, previous), changes|
        current = after[attribute]
        changes[attribute] = [ previous, current ] if previous != current
      end
    end
  end
end
