# frozen_string_literal: true

module Finance
  # Observes live provider balances against soft reserve targets. This command
  # records only state transitions as privacy-safe audit evidence; it never
  # changes refund obligations, organizer ledger facts, or payout allocations.
  class MonitorProviderReserves < Core::BaseService
    ACTION = "finance.provider_reserve.observed"

    def call
      observations = Finance::ProviderReservePolicy.order(:provider, :currency).find_each.map do |policy|
        observe(policy)
      end

      success(observations.compact)
    end

    private

    def observe(policy)
      state, details = state_for(policy)
      Finance::ApplicationRecord.transaction do
        Core::Database::AdvisoryLock.acquire!("finance-provider-reserve-monitor", policy.provider, policy.currency)
        locked_policy = Finance::ProviderReservePolicy.lock.find(policy.id)
        previous = Core::AuditLog
          .for_auditable(locked_policy)
          .for_action(ACTION)
          .recent
          .first
        previous_state = previous&.metadata&.fetch("state", nil)

        next if previous_state == state
        next if state == "healthy" && previous_state.nil?

        Core::Audit::Record.call(
          audit_key: observation_key(locked_policy, previous, state),
          action: ACTION,
          auditable_type: locked_policy.class.name,
          auditable_id: locked_policy.id,
          audited_changes: { state: [ previous_state, state ] },
          metadata: {
            provider: locked_policy.provider,
            currency: locked_policy.currency,
            state:,
            target_minor: locked_policy.target_minor,
            **details
          }
        ).value
      end
    end

    def state_for(policy)
      adapter = Finance::PayoutProviders::Registry.fetch(policy.provider)
      balance = adapter.available_balance(currency: policy.currency)
      return [ "balance_unavailable", { failure_code: "balance_unavailable" } ] if balance.nil?

      amount = balance[:amount_minor] || balance["amount_minor"]
      currency = (balance[:currency] || balance["currency"]).to_s.upcase
      valid = amount.is_a?(Integer) && amount >= 0 && currency.match?(/\A[A-Z]{3}\z/) && currency == policy.currency
      return [ "balance_invalid", { failure_code: "balance_invalid" } ] unless valid

      state = amount < policy.target_minor ? "reserve_breach" : "healthy"
      [ state, { available_minor: amount } ]
    rescue StandardError
      [ "balance_unavailable", { failure_code: "balance_unavailable" } ]
    end

    def observation_key(policy, previous, state)
      previous_id = previous&.id || "initial"
      "finance-provider-reserve-observation-#{policy.id}-#{previous_id}-#{state}"
    end
  end
end
