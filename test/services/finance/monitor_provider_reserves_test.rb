# frozen_string_literal: true

require "test_helper"

module Finance
  class MonitorProviderReservesTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    class FakeAdapter < Finance::PayoutProviders::Adapter
      PROVIDER = "monitor-test"

      attr_accessor :balance

      def initialize(balance: { amount_minor: 10_000, currency: "ETB" })
        @balance = balance
      end

      def available_balance(**)
        balance
      end

      def capabilities = {}
    end

    setup do
      @policy = Finance::ProviderReservePolicy.create!(
        provider: "monitor-test", currency: "ETB", target_minor: 5_000
      )
      @adapter = FakeAdapter.new
      Finance::PayoutProviders::Registry.register("monitor-test", @adapter)
    end

    teardown do
      Finance::PayoutProviders::Registry.instance_variable_set(:@adapters, {})
      Core::AuditLog.where(auditable_type: "Finance::ProviderReservePolicy").delete_all
      Finance::ProviderReservePolicy.where(provider: "monitor-test").delete_all
    end

    test "records one deduplicated breach and a recovery observation" do
      @adapter.balance = { amount_minor: 4_999, currency: "ETB" }

      first = Finance::MonitorProviderReserves.call
      second = Finance::MonitorProviderReserves.call

      assert_predicate first, :success?
      assert_predicate second, :success?
      assert_equal 1, observations.count
      assert_equal "reserve_breach", observations.sole.metadata.fetch("state")
      assert_equal 4_999, observations.sole.metadata.fetch("available_minor")

      @adapter.balance = { amount_minor: 5_000, currency: "ETB" }
      Finance::MonitorProviderReserves.call

      assert_equal 2, observations.count
      assert_equal "healthy", observations.order(:created_at).last.metadata.fetch("state")
    end

    test "alerts again when a recovered reserve breaches later" do
      @adapter.balance = { amount_minor: 4_000, currency: "ETB" }
      Finance::MonitorProviderReserves.call
      @adapter.balance = { amount_minor: 6_000, currency: "ETB" }
      Finance::MonitorProviderReserves.call
      @adapter.balance = { amount_minor: 3_000, currency: "ETB" }
      Finance::MonitorProviderReserves.call

      assert_equal %w[reserve_breach healthy reserve_breach], observations.order(:created_at).map { |row| row.metadata.fetch("state") }
    end

    test "uses one audit observation when overlapping monitors inspect a breach" do
      @adapter.balance = { amount_minor: 4_000, currency: "ETB" }
      start = Queue.new
      ready = Queue.new
      monitor = Finance::MonitorProviderReserves.method(:call)
      Finance::MonitorProviderReserves.define_singleton_method(:call) do
        ready << true
        start.pop
        monitor.call
      end

      threads = 2.times.map { Thread.new { Finance::MonitorProviderReserves.call } }
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)

      assert_equal 1, observations.count
    ensure
      Finance::MonitorProviderReserves.define_singleton_method(:call, monitor) if monitor
    end

    test "deduplicates unavailable and invalid provider observations without raw errors" do
      @adapter.define_singleton_method(:available_balance) { |**| raise "provider unavailable" }

      Finance::MonitorProviderReserves.call
      Finance::MonitorProviderReserves.call

      assert_equal 1, observations.count
      assert_equal "balance_unavailable", observations.sole.metadata.fetch("state")
      refute_match(/Timeout|monitor-test|ETB/, observations.sole.metadata.fetch("failure_code").to_s)

      @adapter.define_singleton_method(:available_balance) do |**|
        balance
      end
      @adapter.balance = { amount_minor: "5,000", currency: "ETB" }
      Finance::MonitorProviderReserves.call

      last_observation = observations.order(:id).last
      assert_equal "balance_invalid", last_observation.metadata.fetch("state")
      assert_nil last_observation.metadata["error"]
    end

    private

    def observations
      Core::AuditLog
        .for_auditable(@policy)
        .for_action("finance.provider_reserve.observed")
        .order(:created_at)
    end
  end
end
