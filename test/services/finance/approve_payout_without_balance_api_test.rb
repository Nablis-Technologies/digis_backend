# frozen_string_literal: true

require "test_helper"

module Finance
  class ApprovePayoutWithoutBalanceApiTest < ActiveSupport::TestCase
    include PayoutTestHelpers

    setup do
      setup_payout_context
      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      create_payout_entry(type: "sale", amount_minor: 10_000)
      @payout = build_payout(idempotency_key: "approval-build").value
    end

    test "records one idempotent approval audit" do
      subject = lambda do
        ApprovePayoutWithoutBalanceApi.call(
          payout: @payout, actor: core_users(:super_admin),
          idempotency_key: "approval-key", reason: "Manual treasury review completed"
        )
      end

      assert_audit_idempotent(
        subject,
        action: ApprovePayoutWithoutBalanceApi::ACTION,
        auditable_type: "Finance::Payout",
        auditable_id: @payout.id
      )
    end

    test "rejects an actor without the explicit finance permission" do
      result = ApprovePayoutWithoutBalanceApi.call(
        payout: @payout, actor: core_users(:core_admin),
        idempotency_key: "approval-forbidden", reason: "Manual treasury review completed"
      )

      assert_predicate result, :failure?
      assert_equal "unauthorized", result.error.code
    end
  end
end
