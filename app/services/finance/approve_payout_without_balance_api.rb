# frozen_string_literal: true

module Finance
  # Records the auditable treasury exception required before dispatching
  # through a provider that cannot report its balance. Dispatch later checks
  # this immutable evidence; approval is never inferred from the caller's
  # request body or a mutable payout flag.
  class ApprovePayoutWithoutBalanceApi < Core::BaseService
    ACTION = "finance.payout.no_balance_api_approved"
    PERMISSION = "finance.payout.approve_no_balance_api"

    def initialize(payout:, actor:, idempotency_key:, reason:)
      @payout = payout
      @actor = actor
      @idempotency_key = idempotency_key
      @reason = reason.to_s.strip
    end

    def call
      return failure(unauthorized_error) unless actor&.has_permission?(PERMISSION)
      return failure(dispatchable_error) unless payout.pending?

      key = Core::IdempotencyKey.new(idempotency_key)
      return failure(reason_error) if reason.blank?

      audit_result = Core::Audit::Record.call(
        audit_key: "finance-payout-no-balance-approval-#{payout.id}-#{key.digest}",
        action: ACTION,
        auditable_type: payout.class.name,
        auditable_id: payout.id,
        actor_type: actor.class.name,
        actor_id: actor.id,
        audited_changes: { approval: [ false, true ] },
        metadata: { payout_id: payout.id, idempotency_key: key.to_s, reason: }
      )
      return failure(audit_result.error) if audit_result.failure?

      success(payout)
    rescue ArgumentError
      failure(Core::BusinessError.new(
        I18n.t("finance.errors.idempotency_key_invalid"),
        code: "idempotency_key_invalid", status: :unprocessable_entity
      ))
    end

    private

    attr_reader :payout, :actor, :idempotency_key, :reason

    def unauthorized_error
      Core::BusinessError.new(
        I18n.t("finance.errors.unauthorized"), code: "unauthorized", status: :forbidden
      )
    end

    def reason_error
      Core::BusinessError.new(
        I18n.t("finance.errors.treasury_approval_reason_required"),
        code: "treasury_approval_reason_required", status: :unprocessable_entity
      )
    end

    def dispatchable_error
      Core::BusinessError.new(
        I18n.t("finance.errors.payout_not_dispatchable"),
        code: "payout_not_dispatchable", status: :unprocessable_entity
      )
    end
  end
end
