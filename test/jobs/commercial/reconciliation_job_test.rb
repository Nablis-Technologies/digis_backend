# frozen_string_literal: true

require "test_helper"

module Commercial
  class ReconciliationJobTest < ActiveJob::TestCase
    test "delegates reconciliation failures so the job can retry" do
      result = Core::BaseService::Result.success({ checked: {}, mismatches: [] })
      called = nil

      original = Commercial::Reconciliation::Run.method(:call)
      Commercial::Reconciliation::Run.define_singleton_method(:call) do |**arguments|
        called = arguments
        result
      end
      assert_nothing_raised { Commercial::ReconciliationJob.perform_now }
    ensure
      Commercial::Reconciliation::Run.define_singleton_method(:call, original) if original

      assert_equal [ :at ], called.keys
    end
  end
end
