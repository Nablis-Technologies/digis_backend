# frozen_string_literal: true

require "digest"

module Finance
  # Updates one provider/currency reserve floor under a deterministic lock.
  # The policy is configuration, not a copied balance, and every change is
  # audited so the no-balance dispatch exception remains reviewable.
  class UpdateProviderReservePolicy < Core::BaseService
    PERMISSION = "finance.reserve_policy.update"

    def initialize(provider:, currency:, target_minor:, actor:, idempotency_key:)
      @provider = provider.to_s.strip.downcase
      @currency = currency.to_s.strip.upcase
      @target_minor = target_minor
      @actor = actor
      @idempotency_key = idempotency_key
    end

    def call
      return failure(finance_error(:unauthorized, code: "unauthorized", status: :forbidden)) unless actor&.has_permission?(PERMISSION)
      return failure(finance_error(:reserve_target_invalid, code: "reserve_target_invalid")) unless target_minor.is_a?(Integer) && target_minor >= 0

      key = Core::IdempotencyKey.new(idempotency_key).to_s
      audit_key = "finance-reserve-policy-#{Digest::SHA256.hexdigest(key)}"

      policy = ActiveRecord::Base.transaction do
        Core::Database::AdvisoryLock.acquire!("finance-reserve-policy", provider, currency)
        existing = Core::AuditLog.find_by(audit_key:)
        if existing
          return success(ProviderReservePolicy.find_by!(provider:, currency:)) if replay_audit?(existing, key)

          return failure(finance_error(:idempotency_conflict, code: "idempotency_conflict"))
        end

        policy = ProviderReservePolicy.lock.find_or_initialize_by(provider:, currency:)
        previous_target = policy.target_minor
        policy.target_minor = target_minor
        policy.save!
        policy.record_audit!(
          "finance.reserve_policy.updated",
          audit_key:,
          audited_changes: { target_minor: [ previous_target, target_minor ] },
          metadata: { idempotency_key: key, provider:, currency: },
          actor:
        )
        policy
      end

      success(policy)
    rescue ArgumentError
      failure(finance_error(:idempotency_key_invalid, code: "idempotency_key_invalid"))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        Core::BusinessError.new(
          I18n.t("finance.errors.reserve_policy_invalid"),
          code: "reserve_policy_invalid", status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      )
    rescue ActiveRecord::RecordNotUnique
      failure(finance_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
    rescue Core::Error => error
      failure(error)
    end

    private

    attr_reader :provider, :currency, :target_minor, :actor, :idempotency_key

    def finance_error(key, code:, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:)
    end

    def replay_audit?(audit, key)
      audit.action == "finance.reserve_policy.updated" &&
        audit.actor_id == actor&.id && audit.metadata["idempotency_key"] == key &&
        audit.metadata["provider"] == provider && audit.metadata["currency"] == currency &&
        audit.audited_changes.dig("target_minor", 1).to_i == target_minor
    end
  end
end
