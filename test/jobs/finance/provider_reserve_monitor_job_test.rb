# frozen_string_literal: true

require "test_helper"

module Finance
  class ProviderReserveMonitorJobTest < ActiveJob::TestCase
    class FakeAdapter < Finance::PayoutProviders::Adapter
      def available_balance(**)
        { amount_minor: 5_000, currency: "ETB" }
      end

      def capabilities = {}
    end

    test "runs the reserve monitor command" do
      policy = Finance::ProviderReservePolicy.create!(
        provider: "monitor-job-test", currency: "ETB", target_minor: 6_000
      )
      Finance::PayoutProviders::Registry.register("monitor-job-test", FakeAdapter.new)

      assert_nothing_raised do
        Finance::ProviderReserveMonitorJob.perform_now
      end

      assert_equal 1, Core::AuditLog.where(
        auditable_type: policy.class.name,
        auditable_id: policy.id,
        action: "finance.provider_reserve.observed"
      ).count
    ensure
      Finance::PayoutProviders::Registry.instance_variable_set(:@adapters, {})
    end
  end
end
